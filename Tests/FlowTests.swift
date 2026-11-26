import AppKit
import WebKit

// Run the actual App loading/discovery/selection bridge with isolated generated files.
final class FlowTests: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let slim = App()
    let fm = FileManager.default
    var base: URL!
    var single: URL!
    var multiple: URL!
    var empty: URL!
    var stage = 0
    var checks = 0
    var sawSearch = false
    var sawScan = false
    var sawPermanentMoved = false
    var selectedPaths: [String] = []
    func check(_ value: Bool, _ name: String) {
        if !value { print("FAIL \(name)"); exit(1) }
        checks += 1; print("PASS \(name)")
    }
    func library(_ relative: String) throws -> URL {
        let url = base.appendingPathComponent(relative)
        for suffix in ["CurrentVersion.flexolibrary", "Event/CurrentVersion.fcpevent", "Event/Original Media/retained.mov", "Event/Render Files/test.cache"] {
            let file = url.appendingPathComponent(suffix)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 37, count: 16384).write(to: file)
        }
        return url
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            check(App.isCreatorLink(URL(string: "https://www.youtube.com/@%E8%83%A1%E5%AD%90%E7%9B%96")!), "verified YouTube channel may open in the external browser")
            check(App.isCreatorLink(URL(string: "https://space.bilibili.com/218610189")!), "verified bilibili space may open in the external browser")
            check(App.isCreatorLink(URL(string: "mailto:horffsky@gmail.com")!), "creator email may open in the mail app")
            check(!App.isCreatorLink(URL(string: "https://example.com")!) && !App.isCreatorLink(URL(string: "javascript:alert(1)")!) && !App.isCreatorLink(URL(fileURLWithPath: "/etc/passwd")), "footer external navigation is limited to the three creator contacts")
            check(App.isFinalCutID("com.apple.FinalCut") && App.isFinalCutID("com.apple.FinalCutTrial") && App.isFinalCutID("com.apple.FinalCut.CreatorStudio") && !App.isFinalCutID("com.apple.TextEdit"), "FCP identification covers standard, trial and variants without confusing other apps")
            base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("NativeFlow-" + UUID().uuidString)
            single = base.appendingPathComponent("single/video 999")
            multiple = base.appendingPathComponent("multiple/video 999")
            empty = base.appendingPathComponent("Empty")
            _ = try library("single/video 999/deep/Only.fcpbundle")
            _ = try library("multiple/video 999/A/Same.fcpbundle")
            _ = try library("multiple/video 999/B/Same.fcpbundle")
            _ = try library("multiple/video 999/Unselected.fcpbundle")
            try fm.createDirectory(at: empty, withIntermediateDirectories: true)
            try Data("plain file".utf8).write(to: multiple.appendingPathComponent("note.txt"))
            func appBundle(_ name: String, _ id: String, _ version: String) throws -> URL {
                let url = base.appendingPathComponent(name + ".app")
                try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":id,"CFBundleVersion":version,"CFBundleShortVersionString":version,"CFBundlePackageType":"APPL"], format: .xml, options: 0)
                try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
                return url
            }
            let oldFCP = try appBundle("Renamed FCP 10", "com.apple.FinalCut", "10.8")
            let newFCP = try appBundle("Renamed FCP 12", "com.apple.FinalCut", "12.4")
            let trialFCP = try appBundle("Final Cut Trial", "com.apple.FinalCutTrial", "12.3")
            let unrelated = try appBundle("Other Editor", "com.example.Editor", "99.0")
            let apps = [oldFCP,newFCP,trialFCP,unrelated]
            check(App.preferredFinalCut(apps, running: [], defaultApp: nil) == newFCP, "renamed installed versions resolve to newest FCP when no default is set")
            check(App.preferredFinalCut(apps, running: [], defaultApp: oldFCP) == oldFCP, "system default FCP version is honored")
            check(App.preferredFinalCut(apps, running: [trialFCP], defaultApp: newFCP) == trialFCP, "already running trial version takes precedence")
            check(App.preferredFinalCut([unrelated], running: [], defaultApp: unrelated) == nil, "unrelated default app is never launched as FCP")
            let actualFCP = slim.finalCutApplication(for: single.appendingPathComponent("deep/Only.fcpbundle"))
            check(actualFCP != nil && App.isFinalCutID(Bundle(url: actualFCP!)?.bundleIdentifier), "macOS resolves the actual installed Final Cut Pro")
            slim.core = SlimCore(journal: base.appendingPathComponent("isolated-journal/recovery.json"))
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            config.userContentController.add(self, name: "events")
            slim.web = DropWebView(frame: NSRect(x: 0,y: 0,width: 820,height: 760), configuration: config)
            slim.web.navigationDelegate = self
            slim.web.loadHTMLString("<script>window.nativeEvent=e=>webkit.messageHandlers.events.postMessage(e)</script>", baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now()+20) { print("FAIL native loading flow timed out at stage \(self.stage)"); exit(1) }
        } catch { print("FAIL \(error)"); exit(1) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { slim.loadLibrary(single) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let event = message.body as? [String: Any], let type = event["type"] as? String else { return }
        let payload = event["payload"] as? [String: Any] ?? [:]
        if type == "searching" { sawSearch = true }
        if type == "scanning" { sawScan = true }
        switch stage {
        case 0:
            if type == "error" { print("FAIL single folder: \(event)"); exit(1) }
            if type == "scan" {
                check(sawSearch && sawScan && slim.scans.count == 1, "opening enclosing folder automatically discovers and scans its single nested library")
                check((payload["root"] as? String)?.hasSuffix("deep/Only.fcpbundle") == true, "automatic scan uses the actual nested FCP library")
                stage = 1; slim.loadLibrary(multiple)
            }
        case 1:
            if type == "error" { print("FAIL multiple folder: \(event)"); exit(1) }
            if type == "librariesFound" {
                let items = payload["items"] as? [[String: Any]] ?? []
                check(items.count == 3 && !slim.busy && slim.scans.isEmpty, "multiple libraries wait for user's selection before analysis")
                selectedPaths = items.compactMap { $0["path"] as? String }.filter { $0.hasSuffix("Same.fcpbundle") }
                stage = 2; slim.scanSelectedLibraries(selectedPaths)
            }
        case 2:
            if type == "scan" {
                check(slim.scans.count == 2 && Set(slim.scans.map(\.root)) == Set(selectedPaths), "native multi selection scans only the two selected libraries")
                let events = slim.scan!.candidates.map(\.event)
                check(Set(events).count == 2 && events.allSatisfy({$0.contains("/Same.fcpbundle / Event")}), "same named libraries retain distinguishable source paths in results")
                check(slim.scan!.total == slim.scans.reduce(0, {$0 + $1.total}), "combined results sum actual library sizes")
                stage = 3; slim.loadLibrary(empty)
            }
        case 3:
            if type == "error" {
                check((event["payload"] as? String)?.contains("没有找到") == true, "empty enclosing folder produces a clear no-library result")
                stage = 4; slim.browse(multiple.path)
            }
        case 4:
            if type == "browseResult" {
                let entries = payload["items"] as? [[String: Any]] ?? []
                let places = payload["places"] as? [[String: Any]] ?? []
                check(entries.contains(where: {$0["name"] as? String == "note.txt" && $0["folder"] as? Bool == false}), "native browser lists regular files alongside folders and libraries")
                check(places.contains(where: {($0["path"] as? String) == NSHomeDirectory()+"/Desktop"}), "native sidebar includes the user's actual Desktop folder")
                let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey],options: [.skipHiddenVolumes]) ?? []
                let external = volumes.filter {(try? $0.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal == false}
                check(external.allSatisfy({volume in places.contains(where: {$0["path"] as? String == volume.path && $0["volume"] as? Bool == true})}), "native sidebar includes every currently mounted external volume (\(external.count) connected)")
                stage = 5; slim.loadLibrary(URL(fileURLWithPath: selectedPaths[0]))
            }
        case 5:
            if type == "scan" {
                check(slim.scans.count == 1 && slim.scans[0].root == selectedPaths[0], "direct library loading also scans automatically")
                check(!fm.fileExists(atPath: slim.core.journal.path), "native load and scan tests never create a cleanup transaction")
                stage = 6
                slim.prepareClean(slim.scan!.candidates.filter(\.eligible).map(\.id), permanently: true)
            }
        case 6:
            if type == "permanentReview" {
                check((payload["items"] as? [String])?.count == 1 && (payload["size"] as? String)?.isEmpty == false, "native direct deletion reviews selected cache and measured size before mutation")
                check(slim.pendingCleanIDs == nil && slim.pendingPermanentIDs?.count == 1 && !fm.fileExists(atPath: slim.core.journal.path), "permanent confirmation is separate and review does not touch files")
                slim.confirmClean()
                check(!slim.busy && !fm.fileExists(atPath: slim.core.journal.path), "normal cleanup confirmation cannot authorize permanent deletion")
                stage = 7; slim.confirmClean(permanently: true)
            }
        case 7:
            if type == "permanentMoved" { sawPermanentMoved = true }
            if type == "error" { print("FAIL native permanent deletion: \(event)"); exit(1) }
            if type == "emptied" {
                do {
                    let record = try slim.core.load()!
                    check(sawPermanentMoved, "native direct flow sends movement completion before permanent deletion result")
                    check(record.entries.allSatisfy { $0.purged == true && !fm.fileExists(atPath: $0.original) && !fm.fileExists(atPath: $0.trash!) }, "confirmed native direct deletion permanently removes only its generated test cache")
                    check(fm.fileExists(atPath: selectedPaths[0]+"/Event/Original Media/retained.mov"), "native permanent flow preserves original media")
                    slim.busy = true; slim.openInFinalCut()
                    check(slim.busy, "FCP launch is ignored during an active file operation")
                    slim.busy = false
                    print("\(checks) native flow checks passed. Generated fixture: \(base.path)"); exit(0)
                } catch { print("FAIL \(error)"); exit(1) }
            }
        default: break
        }
    }
}
@main struct RunFlowTests {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let runner = FlowTests(); app.delegate = runner
        withExtendedLifetime(runner) { app.run() }
    }
}
