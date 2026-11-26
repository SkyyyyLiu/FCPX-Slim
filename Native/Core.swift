import Foundation
import CryptoKit
import Darwin

struct SlimError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func check() throws {
        lock.lock(); let stopped = value; lock.unlock()
        if stopped { throw SlimError("扫描已取消 / Scan cancelled") }
    }
}

struct DiskSize { var bytes: Int64 = 0; var signature = ""; var hardLinks = false }
struct Candidate: Codable {
    var id: String
    var event: String
    var category: String
    var path: String
    var bytes: Int64
    var signature: String
    var eligible: Bool
    var note: String
    var originalMatch: OriginalMatch? = nil
}
struct ScanResult: Codable {
    var root: String
    var identity: String
    var total: Int64
    var candidates: [Candidate]
    var duplicateScanNote: String? = nil
}
struct RecoveryEntry: Codable {
    var original: String
    var trash: String?
    var bytes: Int64
    var signature: String
    var restored = false
    var libraryRoot: String?
    var libraryIdentity: String?
    var trashSignature: String?
    var purged: Bool?
    var purgeStarted: Bool?
    var originalMatch: OriginalMatch? = nil
    var pending: Bool { !restored && purged != true }
}
struct Recovery: Codable {
    var id = UUID().uuidString
    var date = Date()
    var root: String
    var identity: String
    var entries: [RecoveryEntry] = []
}

final class SlimCore {
    let fm = FileManager.default
    let journal: URL
    static let categories = ["Render Files", "Transcoded Media", "Analysis Files"]
    init(journal: URL) { self.journal = journal }

    func statAt(_ url: URL) throws -> stat {
        var s = stat()
        guard lstat(url.path, &s) == 0 else { throw SlimError("无法读取 / Cannot read: \(url.path)") }
        return s
    }
    func realDirectory(_ url: URL) throws {
        let s = try statAt(url)
        guard (s.st_mode & S_IFMT) == S_IFDIR,
              try url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile != true else {
            throw SlimError("需要真实文件夹，不能是链接 / Not a real folder: \(url.path)")
        }
    }
    func regular(_ url: URL) -> Bool {
        guard let s = try? statAt(url) else { return false }
        return (s.st_mode & S_IFMT) == S_IFREG
    }
    func identity(_ url: URL) throws -> String {
        let s = try statAt(url)
        return "\(s.st_dev):\(s.st_ino)"
    }
    func validateLibrary(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "fcpbundle" else {
            throw SlimError("请选择 .fcpbundle 资源库 / Select a .fcpbundle library")
        }
        try realDirectory(url)
        guard regular(url.appendingPathComponent("CurrentVersion.flexolibrary")) else {
            throw SlimError("找不到资源库数据库，拒绝处理 / Missing library database")
        }
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw SlimError("路径包含符号链接，请选择实际位置 / Select the real library location")
        }
    }
    func validateCandidate(_ path: URL, root: URL) throws {
        try validateLibrary(root)
        let event = path.deletingLastPathComponent()
        guard canonicalFilePath(event.deletingLastPathComponent()) == canonicalFilePath(root),
              Self.categories.contains(path.lastPathComponent),
              !["Shared Items", "__Temp", "Original Media"].contains(event.lastPathComponent) else {
            throw SlimError("目录不在允许范围 / Folder is outside the allowlist")
        }
        try realDirectory(event)
        try realDirectory(path)
        guard regular(event.appendingPathComponent("CurrentVersion.fcpevent")) else {
            throw SlimError("事件数据库缺失 / Missing event database")
        }
    }

    // lstat never follows links. Allocation is deduplicated by device/inode.
    // Signatures include every entry, so a changed scan cannot authorize stale writes.
    func measure(_ root: URL, cancellation: Cancellation? = nil, protect: Bool = false,
                 progress: ((Int64) -> Void)? = nil, trashFingerprint: Bool = false) throws -> DiskSize {
        var result = DiskSize(), seen = Set<String>(), hasher = SHA256(), visited = 0
        func walk(_ url: URL, relative: String) throws {
            try cancellation?.check()
            let s = try statAt(url), type = s.st_mode & S_IFMT
            if protect && !relative.isEmpty &&
                (url.lastPathComponent == "Original Media" || url.lastPathComponent == "Settings.plist" ||
                 ["fcpevent", "flexolibrary"].contains(url.pathExtension.lowercased())) {
                throw SlimError("缓存中出现受保护文件 / Protected file inside cache: \(relative)")
            }
            // Finder updates the trashed root's metadata after trashItem returns.
            // Keep inode, mode, size and mtime; only omit that root's ctime.
            let changeTime = trashFingerprint && relative.isEmpty ? "" : "|\(s.st_ctimespec.tv_sec)|\(s.st_ctimespec.tv_nsec)"
            let record = "\(relative)|\(s.st_dev)|\(s.st_ino)|\(s.st_mode)|\(s.st_size)|\(s.st_mtimespec.tv_sec)|\(s.st_mtimespec.tv_nsec)\(changeTime)\n"
            hasher.update(data: Data(record.utf8))
            let key = "\(s.st_dev):\(s.st_ino)"
            if seen.insert(key).inserted { result.bytes += Int64(s.st_blocks) * 512 }
            if type == S_IFREG && s.st_nlink > 1 { result.hardLinks = true }
            visited += 1
            if visited % 128 == 0 { progress?(result.bytes) }
            if type == S_IFDIR {
                for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: {$0.lastPathComponent < $1.lastPathComponent}) {
                    try walk(child, relative: relative + "/" + child.lastPathComponent)
                }
            }
        }
        try walk(root, relative: "")
        result.signature = (trashFingerprint ? "trash-v2:" : "") + hasher.finalize().map { String(format: "%02x", $0) }.joined()
        progress?(result.bytes)
        return result
    }

    struct Discovery {
        var libraries: [URL] = []
        var unreadable: [String] = []
    }
    func discoverLibraries(_ folder: URL, cancellation: Cancellation = Cancellation(), progress: ((Int) -> Void)? = nil) throws -> Discovery {
        try realDirectory(folder)
        var found = Discovery(), visited = 0
        func walk(_ url: URL, top: Bool = false) throws {
            try cancellation.check()
            if url.pathExtension.lowercased() == "fcpbundle" {
                if (try? validateLibrary(url)) != nil { found.libraries.append(url) }
                return // Never traverse a library's media or databases during discovery.
            }
            let children: [URL]
            do { children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles]) }
            catch { if top { throw error }; found.unreadable.append(url.path); return }
            for child in children.sorted(by: {$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}) {
                try cancellation.check()
                visited += 1
                if visited % 64 == 0 { progress?(visited) }
                guard let type = try? statAt(child), (type.st_mode & S_IFMT) == S_IFDIR else { continue }
                let values = try? child.resourceValues(forKeys: [.isPackageKey])
                if values?.isPackage == true && child.pathExtension.lowercased() != "fcpbundle" { continue }
                try walk(child)
            }
        }
        try walk(folder, top: true)
        progress?(visited)
        return found
    }

    func scan(_ input: URL, cancellation: Cancellation = Cancellation(),
              comparisonProgress: ((Int64, Int64) -> Void)? = nil,
              progress: ((Int64) -> Void)? = nil) throws -> ScanResult {
        let selected = input.standardizedFileURL
        try validateLibrary(selected)
        guard let canonical = canonicalFilePath(selected) else { throw SlimError("无法读取资源库 / Could not read library") }
        let root = URL(fileURLWithPath: canonical, isDirectory: true)
        let total = try measure(root, cancellation: cancellation, progress: progress)
        var candidates: [Candidate] = []
        for event in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: {$0.lastPathComponent < $1.lastPathComponent}) {
            try cancellation.check()
            guard (try? realDirectory(event)) != nil,
                  regular(event.appendingPathComponent("CurrentVersion.fcpevent")) else { continue }
            for category in Self.categories {
                let path = event.appendingPathComponent(category)
                guard (try? validateCandidate(path, root: root)) != nil else { continue }
                let size = try measure(path, cancellation: cancellation, protect: true)
                let eligible = category != "Analysis Files" && !size.hardLinks
                let note = size.hardLinks ? "含硬链接，保留 / Hard links: retained" :
                    (category == "Analysis Files" ? "待真实工程验证，保留 / Pending validation: retained" :
                    (category == "Transcoded Media" ? "代理与优化媒体需在 FCP 中重新生成 / Regenerate proxy/optimized media in FCP" : "FCP 可自动重新渲染 / FCP can render again"))
                candidates.append(Candidate(id: UUID().uuidString, event: event.lastPathComponent, category: category,
                    path: path.path, bytes: size.bytes, signature: size.signature, eligible: eligible, note: note))
            }
        }
        var duplicateScanNote: String?
        do {
            let folder = root.deletingLastPathComponent()
            let matches = try findOriginalDuplicates(in: root, source: folder, cancellation: cancellation, progress: comparisonProgress)
            candidates += matches.map { match in
                let event = match.original.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                let target = match.external.pathComponents.dropFirst(folder.pathComponents.count).joined(separator: "/")
                return Candidate(id: UUID().uuidString, event: event, category: "Duplicate Media",
                                 path: match.original.path, bytes: match.bundleBytes, signature: "", eligible: true,
                                 note: target, originalMatch: match)
            }
        } catch {
            try cancellation.check()
            duplicateScanNote = "部分素材无法读取，未勾选重复素材。/ Duplicate media wasn’t selected because some files could not be read."
        }
        return ScanResult(root: root.path, identity: try identity(root), total: total.bytes,
                          candidates: candidates, duplicateScanNote: duplicateScanNote)
    }

    func save(_ recovery: Recovery) throws {
        try fm.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let history = journal.deletingLastPathComponent().appendingPathComponent("transactions")
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        let data = try encoder.encode(recovery)
        try data.write(to: history.appendingPathComponent(recovery.id + ".json"), options: .atomic)
        try data.write(to: journal, options: .atomic)
    }
    func load() throws -> Recovery? {
        var records: [String: Recovery] = [:]
        let history = journal.deletingLastPathComponent().appendingPathComponent("transactions")
        if fm.fileExists(atPath: history.path) {
            for url in try fm.contentsOfDirectory(at: history, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                let record = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: url))
                records[record.id] = record
            }
        }
        if fm.fileExists(atPath: journal.path) {
            let record = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: journal))
            if records[record.id] == nil { records[record.id] = record }
        }
        let ordered = records.values.sorted { $0.date > $1.date }
        return ordered.first(where: {$0.entries.contains(where: {$0.pending})}) ?? ordered.first
    }
    func hasUnrestored() throws -> Bool {
        if try load()?.entries.contains(where: { $0.pending }) == true { return true }
        return try latestLegacyOriginalRelink() != nil
    }

    func clean(_ scan: ScanResult, ids: Set<String>, progress: ((Int64, Int64) -> Void)? = nil) throws -> Recovery {
        try cleanBatch([(scan: scan, ids: ids)], progress: progress)
    }

    // One reviewed selection, then delete only the transaction created by it.
    // If permanent deletion fails, its journal keeps the moved files recoverable.
    func permanentlyCleanBatch(_ selections: [(scan: ScanResult, ids: Set<String>)],
                               beforeOriginal: () throws -> Void = {},
                               progress: ((Int64, Int64) -> Void)? = nil, moved: (() -> Void)? = nil) throws -> Int64 {
        let recovery = try cleanBatch(selections, beforeOriginal: beforeOriginal, progress: progress)
        moved?()
        return try emptyLatest(expectedID: recovery.id, beforeOriginal: beforeOriginal)
    }

    func cleanBatch(_ selections: [(scan: ScanResult, ids: Set<String>)], beforeOriginal: () throws -> Void = {},
                    progress: ((Int64, Int64) -> Void)? = nil) throws -> Recovery {
        guard let first = selections.first else { throw SlimError("清理选择无效 / Invalid cleanup selection") }
        var items: [(item: Candidate, scan: ScanResult)] = []
        for selection in selections {
            let chosen = selection.scan.candidates.filter { selection.ids.contains($0.id) }
            guard !chosen.isEmpty, chosen.count == selection.ids.count, chosen.allSatisfy({$0.eligible}) else {
                throw SlimError("清理选择无效 / Invalid cleanup selection")
            }
            let root = URL(fileURLWithPath: selection.scan.root)
            guard try identity(root) == selection.scan.identity else { throw SlimError("资源库已被替换，请重新扫描 / Library changed; scan again") }
            for item in chosen {
                let path = URL(fileURLWithPath: item.path)
                if let match = item.originalMatch {
                    guard match.original.path == path.path else { throw SlimError("原片路径不一致 / Duplicate media path mismatch") }
                    try validateOriginalMatch(match, in: root)
                } else {
                    try validateCandidate(path, root: root)
                    let fresh = try measure(path, protect: true)
                    guard fresh.signature == item.signature, !fresh.hardLinks else {
                        throw SlimError("文件自扫描后已改变，请重新扫描 / Files changed; scan again")
                    }
                }
                items.append((item, selection.scan))
            }
        }
        guard Set(items.map { $0.item.path }).count == items.count else { throw SlimError("清理选择重复 / Duplicate cleanup selection") }
        var recovery = Recovery(root: first.scan.root, identity: first.scan.identity)
        try save(recovery)
        var done: Int64 = 0
        let total = items.reduce(Int64(0)) {$0 + $1.item.bytes}
        for selected in items {
            let item = selected.item, root = URL(fileURLWithPath: selected.scan.root)
            guard try identity(root) == selected.scan.identity else { throw SlimError("资源库已被替换，请重新扫描 / Library changed; scan again") }
            let path = URL(fileURLWithPath: item.path)
            if let match = item.originalMatch {
                try beforeOriginal()
                try validateOriginalMatch(match, in: root)
                let backup = try plannedOriginalTrash(for: match)
                let fingerprint = try measure(path, trashFingerprint: true).signature
                recovery.entries.append(RecoveryEntry(original: path.path, trash: backup.path, bytes: item.bytes,
                    signature: fingerprint, libraryRoot: selected.scan.root, libraryIdentity: selected.scan.identity,
                    trashSignature: fingerprint, originalMatch: match))
                try save(recovery)
                do {
                    try beforeOriginal()
                    try installOriginalLink(match, in: root, backup: backup)
                } catch {
                    recovery.entries.removeLast()
                    try save(recovery)
                    throw error
                }
                done += item.bytes; progress?(done, total)
                continue
            }
            try validateCandidate(path, root: root)
            guard try measure(path, protect: true).signature == item.signature else {
                throw SlimError("文件发生改变，已停止 / Files changed; stopped")
            }
            recovery.entries.append(RecoveryEntry(original: path.path, bytes: item.bytes, signature: item.signature, libraryRoot: selected.scan.root, libraryIdentity: selected.scan.identity))
            try save(recovery) // Write intent before the system operation.
            var trashed: NSURL?
            do { try fm.trashItem(at: path, resultingItemURL: &trashed) }
            catch {
                recovery.entries.removeLast(); try save(recovery); throw error
            }
            guard let destination = trashed as URL? else { throw SlimError("系统未返回废纸篓路径，请在 Finder 中放回 / Restore using Finder") }
            recovery.entries[recovery.entries.count - 1].trash = destination.path
            do { try save(recovery) }
            catch {
                // If persisting the returned path fails, attempt to put the item back immediately.
                try? fm.moveItem(at: destination, to: path)
                throw SlimError("无法保存恢复记录，已停止。请检查 Finder 废纸篓 / Recovery journal failed; check Finder Trash")
            }
            recovery.entries[recovery.entries.count - 1].trashSignature = try measure(destination, protect: true, trashFingerprint: true).signature
            try save(recovery)
            done += item.bytes; progress?(done, total)
        }
        return recovery
    }

    func restore(beforeOriginal: () throws -> Void = {}, progress: ((Int64, Int64) -> Void)? = nil) throws {
        guard var recovery = try load() else { throw SlimError("没有恢复记录 / No recovery record") }
        let remaining = recovery.entries.indices.filter { recovery.entries[$0].pending }
        guard !remaining.isEmpty else { throw SlimError("没有可恢复的文件 / No restorable files") }
        let total = remaining.reduce(Int64(0)) {$0 + recovery.entries[$1].bytes}
        // Check all conflicts before moving anything, and never overwrite regenerated caches.
        for i in remaining {
            let item = recovery.entries[i], original = URL(fileURLWithPath: item.original)
            let root = URL(fileURLWithPath: item.libraryRoot ?? recovery.root)
            try validateLibrary(root)
            guard try identity(root) == (item.libraryIdentity ?? recovery.identity) else { throw SlimError("原资源库位置已改变 / Original library changed") }
            guard let trash = item.trash else { throw SlimError("操作曾被中断，请在 Finder 废纸篓中放回 / Interrupted operation: use Finder Trash") }
            if let match = item.originalMatch {
                try validateOriginalParent(match.original, in: root)
                let backup = URL(fileURLWithPath: trash)
                try validateOriginalTrashPath(backup, for: match)
                if originalSwapDidNotComplete(match, backup: backup) { continue }
                try validateTrashedOriginal(item, in: root)
                continue
            }
            guard !fm.fileExists(atPath: item.original), (try? statAt(original)) == nil else {
                throw SlimError("原位置已有文件，未覆盖 / Destination exists: \(item.original)")
            }
            let parent = original.deletingLastPathComponent()
            try realDirectory(parent)
            guard canonicalFilePath(parent.deletingLastPathComponent()) == canonicalFilePath(root),
                  Self.categories.contains(original.lastPathComponent),
                  regular(parent.appendingPathComponent("CurrentVersion.fcpevent")) else {
                throw SlimError("恢复位置已改变 / Restore destination changed")
            }
            try realDirectory(URL(fileURLWithPath: trash))
            if let fingerprint = item.trashSignature,
               try measure(URL(fileURLWithPath: trash), protect: true, trashFingerprint: fingerprint.hasPrefix("trash-v2:")).signature != fingerprint {
                throw SlimError("废纸篓中的文件已改变，已停止恢复 / Trashed files changed; restore stopped")
            }
        }
        var done: Int64 = 0
        for i in remaining {
            let item = recovery.entries[i]
            let destination = URL(fileURLWithPath: item.original)
            if let match = item.originalMatch, let trash = item.trash {
                let root = URL(fileURLWithPath: item.libraryRoot ?? recovery.root)
                let backup = URL(fileURLWithPath: trash)
                try beforeOriginal()
                try validateOriginalParent(match.original, in: root)
                try validateOriginalTrashPath(backup, for: match)
                if !originalSwapDidNotComplete(match, backup: backup) {
                    try validateTrashedOriginal(item, in: root)
                    try originalSwap(destination, backup)
                }
                recovery.entries[i].restored = true
                try save(recovery)
                removeStagedOriginalLink(backup, match: match)
                done += item.bytes; progress?(done, total)
                continue
            }
            // Re-check parent resolution and destination immediately before each move.
            let parent = destination.deletingLastPathComponent()
            try realDirectory(parent)
            guard canonicalFilePath(parent) == (item.original as NSString).deletingLastPathComponent,
                  (try? statAt(destination)) == nil else { throw SlimError("恢复位置发生改变 / Restore destination changed") }
            try fm.moveItem(atPath: item.trash!, toPath: item.original)
            recovery.entries[i].restored = true
            try save(recovery)
            done += item.bytes; progress?(done, total)
        }
    }

    // Validate only recorded direct children of this volume's real Trash.
    private func measuredTrash(_ item: RecoveryEntry, recovery: Recovery, stable: Bool) throws -> DiskSize {
        guard let trash = item.trash else { throw SlimError("缺少废纸篓路径 / Missing Trash path") }
        let trashRoot = try fm.url(for: .trashDirectory, in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: item.libraryRoot ?? recovery.root), create: false).standardizedFileURL
        let url = URL(fileURLWithPath: trash).standardizedFileURL
        guard url.deletingLastPathComponent().path == trashRoot.path,
              url.resolvingSymlinksInPath().path == url.path else {
            throw SlimError("文件不在记录的系统废纸篓位置 / Item is outside the system Trash")
        }
        do {
            try realDirectory(url)
            let size = try measure(url, protect: true, trashFingerprint: stable)
            guard !size.hardLinks else { throw SlimError("缓存中出现硬链接，拒绝永久删除 / Hard links: deletion refused") }
            return size
        } catch {
            let issue = error as NSError
            if (issue.domain == NSCocoaErrorDomain && issue.code == 257) ||
               (issue.domain == NSPOSIXErrorDomain && [1, 13].contains(issue.code)) {
                throw SlimError("无法读取系统废纸篓。请在系统设置 → 隐私与安全性 → 完全磁盘访问权限中允许 FCPX Slim，重启应用后再清空；也可在 Finder 废纸篓手动删除 / Trash access denied")
            }
            throw error
        }
    }

    struct EmptyReview {
        var bytes: Int64 = 0
        var estimatedDiskBytes: Int64? = nil
        var hasUnknownOriginalBytes = false
        var refreshedLegacy = false
        var legacySignatures: [String: String] = [:]
    }
    // Old hashes cannot distinguish Finder's metadata update from a real change.
    // Require a new, explicit review of current paths/size instead of silently
    // rewriting the journal or removing its integrity check.
    func reviewEmpty(expectedID: String) throws -> EmptyReview {
        guard let recovery = try load(), recovery.id == expectedID else {
            throw SlimError("清理记录已改变，请重新确认 / Cleanup changed; confirm again")
        }
        let remaining = recovery.entries.filter { $0.pending }
        guard !remaining.isEmpty else { throw SlimError("没有待清空的文件 / Nothing to empty") }
        var review = EmptyReview()
        for item in remaining {
            guard let fingerprint = item.trashSignature else {
                throw SlimError("旧记录缺少清空校验，请先恢复后重新清理 / Restore this older cleanup before emptying")
            }
            if item.originalMatch != nil {
                review.estimatedDiskBytes = review.estimatedDiskBytes ?? review.bytes
                let info = try validateOriginalForPurge(item, recovery: recovery)
                review.bytes += info.bundle
                if let previous = review.estimatedDiskBytes, let current = info.disk {
                    review.estimatedDiskBytes = previous + current
                } else { review.hasUnknownOriginalBytes = true }
                continue
            }
            let stable = try measuredTrash(item, recovery: recovery, stable: true)
            if fingerprint.hasPrefix("trash-v2:") {
                guard stable.signature == fingerprint else {
                    throw SlimError("废纸篓中的文件已改变，拒绝永久删除 / Trashed files changed; permanent deletion refused")
                }
            } else {
                guard fingerprint.count == 64, fingerprint.allSatisfy({ $0.isHexDigit }) else {
                    throw SlimError("清理记录校验无效 / Invalid cleanup fingerprint")
                }
                let legacy = try measuredTrash(item, recovery: recovery, stable: false)
                review.refreshedLegacy = review.refreshedLegacy || legacy.signature != fingerprint
                review.legacySignatures[item.trash!] = stable.signature
            }
            review.bytes += stable.bytes
            if let previous = review.estimatedDiskBytes { review.estimatedDiskBytes = previous + stable.bytes }
        }
        return review
    }

    // Call only after confirmation. Legacy snapshots come from the just-displayed
    // review and live only in memory. Any change after review still stops deletion.
    func emptyLatest(expectedID: String, reviewedLegacySignatures: [String: String] = [:],
                     beforeOriginal: () throws -> Void = {}) throws -> Int64 {
        guard var recovery = try load(), recovery.id == expectedID else {
            throw SlimError("清理记录已改变，请重新确认 / Cleanup changed; confirm again")
        }
        let remaining = recovery.entries.indices.filter { recovery.entries[$0].pending }
        guard !remaining.isEmpty else { throw SlimError("没有待清空的文件 / Nothing to empty") }
        func validate(_ item: RecoveryEntry) throws -> (url: URL, bytes: Int64) {
            guard let trash = item.trash, let fingerprint = item.trashSignature else {
                throw SlimError("旧记录缺少清空校验，请先恢复后重新清理 / Restore this older cleanup before emptying")
            }
            let expected = fingerprint.hasPrefix("trash-v2:") ? fingerprint : reviewedLegacySignatures[trash] ?? fingerprint
            let actual = try measuredTrash(item, recovery: recovery, stable: expected.hasPrefix("trash-v2:"))
            guard actual.signature == expected else {
                throw SlimError("废纸篓中的文件已改变，拒绝永久删除 / Trashed files changed; permanent deletion refused")
            }
            return (URL(fileURLWithPath: trash), actual.bytes)
        }
        // Validate the entire batch before the first irreversible operation.
        for i in remaining {
            let item = recovery.entries[i]
            if item.originalMatch == nil { _ = try validate(item) }
            else { _ = try validateOriginalForPurge(item, recovery: recovery) }
        }
        var total: Int64 = 0
        for i in remaining {
            let item = recovery.entries[i]
            let validated: (url: URL, bytes: Int64)
            if item.originalMatch == nil {
                validated = try validate(item)
            } else {
                try beforeOriginal()
                let original = try validateOriginalForPurge(item, recovery: recovery)
                validated = (original.url, original.disk ?? 0)
            }
            recovery.entries[i].purgeStarted = true
            try save(recovery)
            try fm.removeItem(at: validated.url)
            recovery.entries[i].purged = true
            try save(recovery)
            total += validated.bytes
        }
        return total
    }
}
