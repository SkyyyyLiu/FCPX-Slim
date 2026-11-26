import AppKit
import WebKit

final class DropWebView: WKWebView {
    var receive: ((URL) -> Void)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1, let url = urls.first else { return false }
        receive?(url); return true
    }
}

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var web: DropWebView!
    var busy = false
    var scan: ScanResult?
    var scans: [ScanResult] = []
    var discoveredLibraries: [URL] = []
    var loadedURL: URL?
    var pendingCleanIDs: Set<String>?
    var pendingPermanentIDs: Set<String>?
    var pendingEmptyID: String?
    var pendingEmptyLegacySignatures: [String: String] = [:]
    var cancellation: Cancellation?
    let queue = DispatchQueue(label: "FCPXSlim.files", qos: .userInitiated)
    lazy var core = SlimCore(journal: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FCPXSlim/recovery.json"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 FCPX Slim", action: #selector(about), keyEquivalent: "") .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 FCPX Slim", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let file = NSMenu(title: "文件 / File"); fileItem.submenu = file
        file.addItem(withTitle: "加载资源库… / Load Library…", action: #selector(choose), keyEquivalent: "o").target = self
        file.addItem(withTitle: "撤销上次清理 / Undo Last Cleanup", action: #selector(restore), keyEquivalent: "r").target = self
        let toolsItem = NSMenuItem(); menu.addItem(toolsItem)
        let tools = NSMenu(title: "工具 / Tools"); toolsItem.submenu = tools
        tools.addItem(withTitle: "显示设置… / Display Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "编辑 / Edit"); editItem.submenu = edit
        for (title, action, key) in [("复制 / Copy", "copy:", "c"), ("粘贴 / Paste", "paste:", "v"), ("全选 / Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.add(self, name: "slim")
        web = DropWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.receive = { [weak self] in self?.loadLibrary($0) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FCPX Slim"
        window.minSize = NSSize(width: 620, height: 640)
        window.contentView = web
        window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil)
        let html = Bundle.main.url(forResource: "index", withExtension: "html")!
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func about() {
        let a = NSAlert(); a.messageText = "FCPX Slim " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        a.informativeText = "本地离线 · 点阵界面 · 系统废纸篓恢复\n分析文件暂只读。真实 FCP 工程兼容性仍待验收。"
        a.runModal()
    }
    func emit(_ type: String, _ payload: Any = NSNull()) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": type, "payload": payload]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.nativeEvent(\(json))", completionHandler: nil)
    }
    func object<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value), let obj = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return obj
    }
    func error(_ error: Error) { emit("error", error.localizedDescription) }
    func unsupported() { emit("unsupported", "不支持此文件。请选择 Final Cut Pro 资源库（.fcpbundle）。/ Unsupported file. Select a Final Cut Pro library (.fcpbundle).") }
    static func isFinalCutID(_ id: String?) -> Bool {
        guard let id = id else { return false }
        return id == "com.apple.FinalCut" || id == "com.apple.FinalCutTrial" || id.hasPrefix("com.apple.FinalCut.")
    }
    func fcpRunning() -> Bool { NSWorkspace.shared.runningApplications.contains { Self.isFinalCutID($0.bundleIdentifier) } }

    static func preferredFinalCut(_ urls: [URL], running: [URL], defaultApp: URL?) -> URL? {
        let available = Array(Set(urls.map { $0.standardizedFileURL })).filter {
            $0.pathExtension == "app" && Self.isFinalCutID(Bundle(url: $0)?.bundleIdentifier)
        }
        return available.sorted { a, b in
            let ar = running.contains(a), br = running.contains(b)
            if ar != br { return ar }
            if (a == defaultApp) != (b == defaultApp) { return a == defaultApp }
            let av = Bundle(url: a)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let bv = Bundle(url: b)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let order = av.compare(bv, options: .numeric)
            return order == .orderedSame ? a.path < b.path : order == .orderedDescending
        }.first
    }
    func finalCutApplication(for library: URL) -> URL? {
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications.filter { Self.isFinalCutID($0.bundleIdentifier) }.compactMap(\.bundleURL)
        var candidates = running + workspace.urlsForApplications(toOpen: library)
        for id in ["com.apple.FinalCut", "com.apple.FinalCutTrial"] {
            candidates += workspace.urlsForApplications(withBundleIdentifier: id)
        }
        return Self.preferredFinalCut(candidates, running: running, defaultApp: workspace.urlForApplication(toOpen: library))
    }
    func openInFinalCut() {
        guard !busy, !scans.isEmpty else { return }
        do {
            let libraries = try scans.map { result -> URL in
                let url = URL(fileURLWithPath: result.root)
                try core.validateLibrary(url)
                guard try core.identity(url) == result.identity else { throw SlimError("资源库已改变，请重新加载 / Library changed; load again") }
                return url
            }
            guard let app = finalCutApplication(for: libraries[0]) else {
                throw SlimError("未找到已安装的 Final Cut Pro。请先安装，再点击导入 FCP。/ Final Cut Pro is not installed.")
            }
            pendingCleanIDs = nil; pendingPermanentIDs = nil; pendingEmptyID = nil
            busy = true; emit("openingFCP")
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.open(libraries, withApplicationAt: app, configuration: configuration) { application, error in
                DispatchQueue.main.async {
                    self.busy = false
                    if let error = error { self.emit("fcpOpenFailed", error.localizedDescription) }
                    else if application == nil { self.emit("fcpOpenFailed", "未能启动 Final Cut Pro / Could not launch Final Cut Pro") }
                    else { self.emit("fcpOpened", libraries.map(\.lastPathComponent).joined(separator: "、")) }
                }
            }
        } catch { emit("fcpOpenFailed", error.localizedDescription) }
    }
    func requireClosed() -> Bool {
        if fcpRunning() { error(SlimError("请先退出 Final Cut Pro 再操作 / Quit Final Cut Pro first")); return false }
        return true
    }
    private func requireClosedForDuplicateMedia() throws {
        guard !fcpRunning() else { throw SlimError("请先退出 Final Cut Pro 再操作。 / Quit Final Cut Pro first.") }
    }
    @objc func choose() {
        guard !busy else { return }
        emit("choose")
    }
    @objc func showSettings() { emit("showSettings") }
    func loadLibrary(_ input: URL) {
        guard !busy else { return }
        let url = input.standardizedFileURL
        if url.pathExtension.lowercased() == "fcpbundle" { beginScans([url]); return }
        do { try core.realDirectory(url) } catch { unsupported(); return }
        busy = true; scan = nil; scans = []; discoveredLibraries = []
        let token = Cancellation(); cancellation = token
        emit("loaded", ["name": url.lastPathComponent, "path": url.path])
        emit("searching", url.lastPathComponent)
        queue.async {
            do {
                let result = try self.core.discoverLibraries(url, cancellation: token) { count in
                    DispatchQueue.main.async { self.emit("searchProgress", count) }
                }
                DispatchQueue.main.async {
                    self.busy = false
                    if result.libraries.count == 1 { self.beginScans(result.libraries); return }
                    if result.libraries.isEmpty {
                        let text = result.unreadable.isEmpty ? "这个文件夹里没有找到 Final Cut Pro 资源库（.fcpbundle）。/ No Final Cut Pro libraries found in this folder." : "未找到资源库，且部分子文件夹无法读取。请检查文件夹访问权限。/ No libraries found; some subfolders could not be read."
                        self.error(SlimError(text)); return
                    }
                    self.discoveredLibraries = result.libraries
                    self.emit("librariesFound", ["items": result.libraries.map { ["name": $0.lastPathComponent, "path": $0.path, "library": true] }, "unreadable": result.unreadable.count])
                }
            } catch { DispatchQueue.main.async { self.busy = false; self.error(error) } }
        }
    }
    func scanSelectedLibraries(_ paths: [String]) {
        guard !busy, !paths.isEmpty, Set(paths).count == paths.count else { return }
        let allowed = Set(discoveredLibraries.map { $0.path })
        guard Set(paths).isSubset(of: allowed) else { error(SlimError("资源库选择已改变，请重新加载 / Library selection changed")); return }
        beginScans(paths.map { URL(fileURLWithPath: $0) })
    }
    func browse(_ path: String) {
        guard !busy else { return }
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        var url = URL(fileURLWithPath: path.hasPrefix("/") ? path : UserDefaults.standard.string(forKey: "lastBrowserFolder") ?? desktop.path).standardizedFileURL
        if path.isEmpty && (try? core.realDirectory(url)) == nil { url = desktop }
        do {
            try core.realDirectory(url)
            let entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles])
                .compactMap { child -> [String: Any]? in
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey, .isPackageKey])
                    guard values?.isHidden != true else { return nil }
                    let library = child.pathExtension.lowercased() == "fcpbundle" && values?.isSymbolicLink != true
                    let folder = values?.isDirectory == true && values?.isSymbolicLink != true && values?.isPackage != true && !library
                    return ["name": child.lastPathComponent, "path": child.path, "library": library, "folder": folder]
                }
                .sorted { a, b in
                    let first = a["folder"] as? Bool == true, second = b["folder"] as? Bool == true
                    if first != second { return first }
                    return (a["name"] as? String ?? "").localizedStandardCompare(b["name"] as? String ?? "") == .orderedAscending
                }
            let user = URL(fileURLWithPath: NSHomeDirectory())
            let common = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"]
            var places = (try fm.contentsOfDirectory(at: user, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]))
                .filter { (try? core.realDirectory($0)) != nil }
                .sorted { a, b in
                    let ai = common.firstIndex(of: a.lastPathComponent) ?? 99, bi = common.firstIndex(of: b.lastPathComponent) ?? 99
                    return ai == bi ? a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending : ai < bi
                }
                .map { ["name": fm.displayName(atPath: $0.path), "path": $0.path, "volume": false] as [String: Any] }
            let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey], options: [.skipHiddenVolumes]) ?? []
            places += volumes.filter { $0.path == "/" || (try? $0.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal == false }
                .map { ["name": fm.displayName(atPath: $0.path), "path": $0.path, "volume": true] as [String: Any] }
            var crumbs: [[String: String]] = [], cursor = url
            while true {
                crumbs.insert(["name": fm.displayName(atPath: cursor.path), "path": cursor.path], at: 0)
                if cursor.path == "/" { break }; cursor.deleteLastPathComponent()
            }
            UserDefaults.standard.set(url.path, forKey: "lastBrowserFolder")
            emit("browseResult", ["path": url.path, "name": fm.displayName(atPath: url.path), "items": entries, "places": places, "crumbs": crumbs])
        } catch { emit("browseError", error.localizedDescription) }
    }
    func combined(_ results: [ScanResult]) -> ScanResult? {
        guard let first = results.first else { return nil }
        if results.count == 1 { return first }
        return ScanResult(root: "已选 \(results.count) 个资源库", identity: "batch", total: results.reduce(0) { $0 + $1.total }, candidates: results.flatMap { result in
            let name = URL(fileURLWithPath: result.root).lastPathComponent
            let prefix = results.filter { URL(fileURLWithPath: $0.root).lastPathComponent == name }.count > 1 ? result.root : name
            return result.candidates.map { item in
                var labeled = item
                labeled.event = prefix + " / " + item.event
                return labeled
            }
        }, duplicateScanNote: results.compactMap(\.duplicateScanNote).first)
    }
    func beginScans(_ urls: [URL]) {
        guard !busy, !urls.isEmpty else { return }
        do { for url in urls { try core.validateLibrary(url) } } catch { unsupported(); return }
        pendingCleanIDs = nil; pendingPermanentIDs = nil; pendingEmptyID = nil; pendingEmptyLegacySignatures = [:]
        busy = true; scan = nil; scans = []; discoveredLibraries = []
        loadedURL = urls.first
        let token = Cancellation(); cancellation = token
        let name = urls.count == 1 ? urls[0].lastPathComponent : "已选 \(urls.count) 个资源库"
        emit("loaded", ["name": name, "path": urls[0].path])
        emit("scanning", name)
        queue.async {
            do {
                var results: [ScanResult] = [], completedBytes: Int64 = 0
                for (index, url) in urls.enumerated() {
                    try token.check()
                    let alreadyRead = completedBytes
                    let libraryCount = Double(urls.count)
                    let result = try self.core.scan(url, cancellation: token, comparisonProgress: { bytes, total in
                        let fraction = min(1, Double(bytes) / Double(max(1, total)))
                        let overall = (Double(index) + 0.08 + 0.92 * fraction) / libraryCount
                        DispatchQueue.main.async { self.emit("scanWork", ["fraction": overall, "comparing": true]) }
                    }, progress: { bytes in
                        DispatchQueue.main.async { self.emit("scanProgress", alreadyRead + bytes) }
                    })
                    results.append(result); completedBytes += result.total
                    if index + 1 < urls.count {
                        let overall = Double(index + 1) / libraryCount
                        DispatchQueue.main.async { self.emit("scanWork", ["fraction": overall, "comparing": false]) }
                    }
                }
                let combined = self.combined(results)!
                DispatchQueue.main.async { self.busy = false; self.scans = results; self.scan = combined; self.emit("scan", self.object(combined)) }
            } catch { DispatchQueue.main.async { self.busy = false; self.error(error) } }
        }
    }
    func prepareClean(_ ids: [String], permanently: Bool = false) {
        guard !busy, let scan = scan, requireClosed() else { return }
        let items = scan.candidates.filter { ids.contains($0.id) }
        guard items.count == ids.count, !items.isEmpty, items.allSatisfy({$0.eligible}) else { error(SlimError("清理选择无效 / Invalid selection")); return }
        guard Set(ids).count == ids.count else { error(SlimError("清理选择重复 / Duplicate selection")); return }
        pendingCleanIDs = permanently ? nil : Set(ids)
        pendingPermanentIDs = permanently ? Set(ids) : nil
        pendingEmptyID = nil; pendingEmptyLegacySignatures = [:]
        let bytes = items.reduce(Int64(0)) {$0 + $1.bytes}
        let duplicates = items.compactMap(\.originalMatch)
        var payload: [String: Any] = [
            "items": items.map { item in
                guard let match = item.originalMatch else { return "\(item.event) / \(item.category)" }
                return "\(item.event) / 重复素材 / \(match.original.lastPathComponent) → \(item.note)"
            },
            "size": ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
        ]
        if !duplicates.isEmpty {
            payload["hasDuplicates"] = true
            let disk = duplicates.compactMap(\.privateBytes)
            if disk.count == duplicates.count {
                let cacheBytes = items.filter { $0.originalMatch == nil }.reduce(Int64(0)) { $0 + $1.bytes }
                payload["estimatedDisk"] = ByteCountFormatter.string(fromByteCount: cacheBytes + disk.reduce(0, +), countStyle: .binary)
            }
        }
        emit(permanently ? "permanentReview" : "cleanReview", payload)
    }
    func confirmClean(permanently: Bool = false) {
        guard !busy, scan != nil, let ids = permanently ? pendingPermanentIDs : pendingCleanIDs, requireClosed() else { return }
        let selections = scans.compactMap { result -> (scan: ScanResult, ids: Set<String>)? in
            let selected = ids.intersection(Set(result.candidates.map { $0.id }))
            return selected.isEmpty ? nil : (result, selected)
        }
        guard selections.reduce(0, { $0 + $1.ids.count }) == ids.count else { error(SlimError("清理选择无效 / Invalid selection")); return }
        pendingCleanIDs = nil; pendingPermanentIDs = nil
        busy = true; emit(permanently ? "deleting" : "cleaning")
        queue.async {
            do {
                if permanently {
                    let bytes = try self.core.permanentlyCleanBatch(selections, beforeOriginal: self.requireClosedForDuplicateMedia, progress: { done, total in
                        DispatchQueue.main.async { self.emit("cleanProgress", ["done": done, "total": total]) }
                    }, moved: {
                        DispatchQueue.main.async { self.emit("permanentMoved") }
                    })
                    DispatchQueue.main.async { self.busy = false; self.emit("emptied", bytes); self.recoveryState() }
                    return
                }
                let recovery = try self.core.cleanBatch(selections, beforeOriginal: self.requireClosedForDuplicateMedia) { done, total in
                    DispatchQueue.main.async { self.emit("cleanProgress", ["done": done, "total": total]) }
                }
                DispatchQueue.main.async { self.busy = false; self.emit("cleaned", self.object(recovery)) }
            } catch { DispatchQueue.main.async { self.busy = false; self.error(error); self.recoveryState() } }
        }
    }
    func recoveryState() {
        do { emit("recovery", try core.hasUnrestored()) } catch { self.error(error) }
    }
    @objc func restore() {
        guard !busy, requireClosed() else { return }
        busy = true; emit("restoring")
        queue.async {
            do {
                let record = try self.core.load()
                let pending = record?.entries.filter(\.pending) ?? []
                let roots: [URL]
                if let legacy = try self.core.latestLegacyOriginalRelink(),
                   pending.isEmpty || legacy.date > record!.date {
                    try self.core.undoOriginalRelinks(check: self.requireClosedForDuplicateMedia)
                    roots = [legacy.library]
                } else {
                    let paths = Set(pending.compactMap { $0.libraryRoot ?? record?.root })
                    try self.core.restore(beforeOriginal: self.requireClosedForDuplicateMedia) { done, total in
                        DispatchQueue.main.async { self.emit("restoreProgress", ["done": done, "total": total]) }
                    }
                    roots = paths.sorted().map { URL(fileURLWithPath: $0) }
                }
                let rescanned = try roots.map { try self.core.scan($0) }
                let combined = self.combined(rescanned)
                DispatchQueue.main.async {
                    self.busy = false; self.scans = rescanned; self.scan = combined
                    self.emit("restored", combined.map { self.object($0) } ?? NSNull()); self.recoveryState()
                }
            } catch { DispatchQueue.main.async { self.busy = false; self.error(error); self.recoveryState() } }
        }
    }
    func prepareEmpty() {
        guard !busy, requireClosed() else { return }
        do {
            guard let recovery = try core.load() else { throw SlimError("没有待清空的文件 / Nothing to empty") }
            let entries = recovery.entries.filter { $0.pending }
            guard !entries.isEmpty else { throw SlimError("没有待清空的文件 / Nothing to empty") }
            let review = try core.reviewEmpty(expectedID: recovery.id)
            pendingEmptyID = recovery.id
            pendingEmptyLegacySignatures = review.legacySignatures
            let bytes = review.bytes
            var payload: [String: Any] = [
                "refreshedLegacy": review.refreshedLegacy,
                "items": entries.map { entry in
                    if let match = entry.originalMatch {
                        return "重复素材 / \(match.original.lastPathComponent) → \(match.external.path)"
                    }
                    if review.refreshedLegacy, let trash = entry.trash { return trash }
                    let original = URL(fileURLWithPath: entry.original)
                    return original.deletingLastPathComponent().lastPathComponent + " / " + original.lastPathComponent
                },
                "size": ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
            ]
            if entries.contains(where: { $0.originalMatch != nil }) {
                payload["hasDuplicates"] = true
                if !review.hasUnknownOriginalBytes, let disk = review.estimatedDiskBytes {
                    payload["estimatedDisk"] = ByteCountFormatter.string(fromByteCount: disk, countStyle: .binary)
                }
            }
            emit("emptyReview", payload)
        } catch { self.error(error) }
    }
    func confirmEmpty() {
        guard !busy, let id = pendingEmptyID, requireClosed() else { return }
        let legacySignatures = pendingEmptyLegacySignatures
        pendingEmptyID = nil; pendingEmptyLegacySignatures = [:]
        busy = true; emit("emptying")
        queue.async {
            do {
                let bytes = try self.core.emptyLatest(expectedID: id, reviewedLegacySignatures: legacySignatures,
                                                      beforeOriginal: self.requireClosedForDuplicateMedia)
                DispatchQueue.main.async { self.busy = false; self.emit("emptied", bytes); self.recoveryState() }
            } catch { DispatchQueue.main.async { self.busy = false; self.error(error); self.recoveryState() } }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let obj = message.body as? [String: Any], let command = obj["command"] as? String else { return }
        switch command {
        case "ready": recoveryState()
        case "openCreator": if let raw = obj["url"] as? String, let url = URL(string: raw), Self.isCreatorLink(url) { NSWorkspace.shared.open(url) }
        case "choose": choose()
        case "browse": browse(obj["path"] as? String ?? "")
        case "loadPath", "scanPath": if let path = obj["path"] as? String, path.hasPrefix("/") { loadLibrary(URL(fileURLWithPath: path)) } else { unsupported() }
        case "scanLibraries": if let paths = obj["paths"] as? [String] { scanSelectedLibraries(paths) }
        case "reset": if !busy { loadedURL = nil; scan = nil; scans = []; pendingCleanIDs = nil; pendingPermanentIDs = nil; pendingEmptyID = nil }
        case "cancel": cancellation?.cancel()
        case "prepareClean": if let ids = obj["ids"] as? [String] { prepareClean(ids) }
        case "confirmClean": confirmClean()
        case "preparePermanent": if let ids = obj["ids"] as? [String] { prepareClean(ids, permanently: true) }
        case "confirmPermanent": confirmClean(permanently: true)
        case "openFCP": openInFinalCut()
        case "cancelReview": pendingCleanIDs = nil; pendingPermanentIDs = nil; pendingEmptyID = nil; pendingEmptyLegacySignatures = [:]
        case "restore": restore()
        case "prepareEmpty": prepareEmpty()
        case "confirmEmpty": confirmEmpty()
        case "trash": NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
        default: break
        }
    }
    static let creatorLinks: Set<String> = [
        "https://www.youtube.com/@%E8%83%A1%E5%AD%90%E7%9B%96",
        "https://space.bilibili.com/218610189",
        "mailto:horffsky@gmail.com"
    ]
    static func isCreatorLink(_ url: URL) -> Bool { creatorLinks.contains(url.absoluteString) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if Self.isCreatorLink(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        let own = Bundle.main.url(forResource: "index", withExtension: "html")!
        decisionHandler(url.isFileURL && url.path == own.path ? .allow : .cancel)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy { cancellation?.cancel(); return .terminateCancel }; return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if busy { cancellation?.cancel(); return false }; return true }
}

#if !FLOW_TESTS
@main struct Launcher {
    static func main() {
        let app = NSApplication.shared
        let delegate = App(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
