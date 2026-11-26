import Foundation
import CryptoKit
import Darwin

struct OriginalFileStamp: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    let bytes: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    let links: UInt16

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        bytes = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanos = value.st_ctimespec.tv_nsec
        links = value.st_nlink
    }

    func sameFileAfterMove(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && bytes == other.bytes &&
        modifiedSeconds == other.modifiedSeconds && modifiedNanos == other.modifiedNanos &&
        links == other.links
    }
}

struct OriginalMatch: Codable {
    let original: URL
    let external: URL
    let originalStamp: OriginalFileStamp
    let externalStamp: OriginalFileStamp
    let bundleBytes: Int64
    let privateBytes: Int64?
}

private struct OriginalRelinkRecord: Codable {
    struct Entry: Codable {
        let match: OriginalMatch
        let backup: URL
    }
    let library: URL
    let identity: String
    let date: Date
    var entries: [Entry] = []
}

extension SlimCore {
    private var originalHistory: URL {
        journal.deletingLastPathComponent().appendingPathComponent("original-relinks", isDirectory: true)
    }

    private func originalFailure(_ text: String, _ url: URL) -> SlimError {
        SlimError("\(text)\n\(url.path)")
    }

    private func originalDirectories(in library: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .sorted { $0.path < $1.path }
            .compactMap { event in
                guard regular(event.appendingPathComponent("CurrentVersion.fcpevent")),
                      (try? realDirectory(event)) != nil else { return nil }
                let media = event.appendingPathComponent("Original Media", isDirectory: true)
                return (try? realDirectory(media)) == nil ? nil : media
            }
    }

    func validateOriginalParent(_ url: URL, in library: URL) throws {
        let media = url.deletingLastPathComponent()
        let event = media.deletingLastPathComponent()
        guard media.lastPathComponent == "Original Media",
              canonicalFilePath(event.deletingLastPathComponent()) == canonicalFilePath(library),
              regular(event.appendingPathComponent("CurrentVersion.fcpevent")) else {
            throw originalFailure("原片路径已改变 / Original path changed", url)
        }
        try realDirectory(event)
        try realDirectory(media)
    }

    func canonicalFilePath(_ url: URL) -> String? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return String(cString: path)
    }

    private func fileStamp(_ url: URL) throws -> OriginalFileStamp {
        let value = try statAt(url)
        guard (value.st_mode & S_IFMT) == S_IFREG else {
            throw originalFailure("需要真实文件 / Expected a regular file", url)
        }
        return OriginalFileStamp(value)
    }

    private func originalDigest(_ url: URL, stamp: OriginalFileStamp, cancellation: Cancellation,
                                onRead: (Int) -> Void) throws -> SHA256.Digest {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw originalFailure("无法读取原片 / Could not read media", url) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var value = stat()
        guard fstat(fd, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG, OriginalFileStamp(value) == stamp else {
            throw originalFailure("文件已改变，请重新扫描 / File changed; scan again", url)
        }
        var hash = SHA256()
        while true {
            try cancellation.check()
            guard let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { break }
            hash.update(data: data)
            onRead(data.count)
        }
        guard fstat(fd, &value) == 0, OriginalFileStamp(value) == stamp, try fileStamp(url) == stamp else {
            throw originalFailure("文件已改变，请重新扫描 / File changed; scan again", url)
        }
        return hash.finalize()
    }

    private func canUseOriginalFile(_ url: URL) throws -> Bool {
        let info = try url.resourceValues(forKeys: [.isAliasFileKey])
        guard info.isAliasFile != true else { return false }
        // A data-fork match alone does not verify media with a resource fork.
        let size = getxattr(url.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
        return size == 0 || (size == -1 && errno == ENOATTR)
    }

    private func originalPrivateBytes(_ url: URL) -> Int64? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 32)
        let status = buffer.withUnsafeMutableBytes {
            getattrlist(url.path, &attributes, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes {
            let length = $0.loadUnaligned(as: UInt32.self)
            let returned = $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            guard length >= 32, returned & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            let bytes = $0.loadUnaligned(fromByteOffset: 24, as: Int64.self)
            return bytes >= 0 ? bytes : nil
        }
    }

    func findOriginalDuplicates(in library: URL, source: URL, cancellation: Cancellation,
                                progress: ((Int64, Int64) -> Void)? = nil) throws -> [OriginalMatch] {
        try validateLibrary(library)
        try realDirectory(source)
        guard let sourcePath = canonicalFilePath(source) else {
            throw originalFailure("无法读取素材文件夹 / Could not read source folder", source)
        }
        let folder = URL(fileURLWithPath: sourcePath, isDirectory: true)
        guard !folder.pathComponents.contains(where: { $0.lowercased().hasSuffix(".fcpbundle") }) else {
            throw SlimError("请选择资源库外的原片文件夹 / Select a folder outside any Final Cut library")
        }

        let originals = try originalDirectories(in: library).flatMap {
            try fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                .sorted { $0.path < $1.path }
        }
        var files: [(URL, stat)] = []
        for url in originals {
            try cancellation.check()
            let value = try statAt(url)
            if (value.st_mode & S_IFMT) == S_IFREG, value.st_nlink == 1, value.st_size > 0,
               try canUseOriginalFile(url) {
                files.append((url, value))
            }
        }
        guard !files.isEmpty else { return [] }
        let sizes = Set(files.map { $0.1.st_size })
        var externalBySize: [Int64: [(URL, OriginalFileStamp)]] = [:]
        var readFailure: Error?
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isPackageKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { _, error in readFailure = error; return false }) else {
            throw originalFailure("无法读取素材文件夹 / Could not read source folder", source)
        }
        for case let url as URL in walker {
            try cancellation.check()
            let value = try statAt(url)
            let type = value.st_mode & S_IFMT
            if type == S_IFDIR && url.pathExtension.lowercased() == "fcpbundle" {
                walker.skipDescendants()
            } else if type == S_IFREG && sizes.contains(value.st_size),
                      canonicalFilePath(url) == url.path, try canUseOriginalFile(url) {
                externalBySize[value.st_size, default: []].append((url, OriginalFileStamp(value)))
            }
        }
        if let readFailure = readFailure { throw readFailure }

        let comparable = files.filter { externalBySize[$0.1.st_size] != nil }
        guard !comparable.isEmpty else { return [] }
        var remainingBySize = Dictionary(grouping: comparable, by: { $0.1.st_size }).mapValues(\.count)
        var total = comparable.reduce(Int64(0)) { $0 + $1.1.st_size }
        for (size, sources) in externalBySize { total += size * Int64(sources.count) }
        let clock = ProcessInfo.processInfo
        var read: Int64 = 0
        var lastReport = clock.systemUptime
        progress?(0, total)
        func reportRead(_ bytes: Int) {
            read += Int64(bytes)
            guard let progress else { return }
            let now = clock.systemUptime
            if now - lastReport >= 0.12 {
                lastReport = now
                progress(read, total)
            }
        }
        var externalDigests: [URL: SHA256.Digest] = [:]
        var matches: [OriginalMatch] = []
        for (url, value) in comparable {
            try cancellation.check()
            guard let candidates = externalBySize[value.st_size] else { continue }
            let stamp = OriginalFileStamp(value)
            let digest = try originalDigest(url, stamp: stamp, cancellation: cancellation, onRead: reportRead)
            var match: (URL, OriginalFileStamp)?
            for (candidate, candidateStamp) in candidates {
                let externalDigest: SHA256.Digest
                if let cached = externalDigests[candidate] {
                    externalDigest = cached
                } else {
                    externalDigest = try originalDigest(candidate, stamp: candidateStamp, cancellation: cancellation, onRead: reportRead)
                    externalDigests[candidate] = externalDigest
                }
                if externalDigest == digest {
                    if match != nil { match = nil; break }
                    match = (candidate, candidateStamp)
                }
            }
            remainingBySize[value.st_size, default: 0] -= 1
            if remainingBySize[value.st_size] == 0 {
                // Once this size group is done, ambiguous matches can leave candidates unread.
                let skipped = candidates.reduce(Int64(0)) { $0 + (externalDigests[$1.0] == nil ? $1.1.bytes : 0) }
                total -= skipped
            }
            if let (external, externalStamp) = match {
                matches.append(OriginalMatch(original: url, external: external, originalStamp: stamp,
                    externalStamp: externalStamp, bundleBytes: Int64(value.st_blocks) * 512,
                    privateBytes: originalPrivateBytes(url)))
            }
        }
        progress?(read, total)
        return matches
    }

    func validateOriginalMatch(_ match: OriginalMatch, in library: URL) throws {
        try validateOriginalParent(match.original, in: library)
        guard canonicalFilePath(match.external) == match.external.path,
              !match.external.pathComponents.contains(where: { $0.lowercased().hasSuffix(".fcpbundle") }),
              try fileStamp(match.original) == match.originalStamp,
              try fileStamp(match.external) == match.externalStamp,
              try canUseOriginalFile(match.original), try canUseOriginalFile(match.external) else {
            throw originalFailure("文件或路径已改变，请重新扫描 / Media or path changed; scan again", match.original)
        }
    }

    func originalSwap(_ first: URL, _ second: URL) throws {
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
            let code = errno
            throw originalFailure("无法安全交换文件 / Could not swap files: \(String(cString: strerror(code)))", first)
        }
    }

    func plannedOriginalTrash(for match: OriginalMatch) throws -> URL {
        let root = try fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: match.original, create: true)
            .resolvingSymlinksInPath()
        let backup = root.appendingPathComponent("FCPX Slim " + UUID().uuidString + " " + match.original.lastPathComponent)
        // Allow the filesystem's maximum component length, even when the original name already fills it.
        let destination = backup.lastPathComponent.utf8.count <= 255 ? backup
            : root.appendingPathComponent("FCPX Slim " + UUID().uuidString)
        try validateOriginalTrashPath(destination, for: match)
        return destination
    }

    func validateOriginalTrashPath(_ backup: URL, for match: OriginalMatch) throws {
        let root = try fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: match.original, create: false)
            .resolvingSymlinksInPath()
        try realDirectory(root)
        guard backup.deletingLastPathComponent().path == root.path,
              backup.lastPathComponent.hasPrefix("FCPX Slim "),
              try statAt(root).st_dev == match.originalStamp.device else {
            throw originalFailure("文件不在记录的系统废纸篓位置 / Item is outside the system Trash", backup)
        }
    }

    func removeStagedOriginalLink(_ backup: URL, match: OriginalMatch) {
        if (try? fm.destinationOfSymbolicLink(atPath: backup.path)) == match.external.path {
            _ = unlink(backup.path)
        }
    }

    func installOriginalLink(_ match: OriginalMatch, in library: URL, backup: URL) throws {
        try validateOriginalTrashPath(backup, for: match)
        try fm.createSymbolicLink(atPath: backup.path, withDestinationPath: match.external.path)
        do {
            try validateOriginalMatch(match, in: library)
            try originalSwap(match.original, backup)
        } catch {
            removeStagedOriginalLink(backup, match: match)
            throw error
        }
    }

    func originalSwapDidNotComplete(_ match: OriginalMatch, backup: URL) -> Bool {
        guard let current = try? fileStamp(match.original), match.originalStamp.sameFileAfterMove(current) else { return false }
        return (try? fm.destinationOfSymbolicLink(atPath: backup.path)) == match.external.path ||
            (try? statAt(backup)) == nil
    }

    @discardableResult
    func validateTrashedOriginal(_ entry: RecoveryEntry, in library: URL) throws -> URL {
        guard let match = entry.originalMatch, let path = entry.trash else {
            throw SlimError("缺少原片恢复记录 / Missing original recovery entry")
        }
        try validateOriginalParent(match.original, in: library)
        let backup = URL(fileURLWithPath: path)
        try validateOriginalTrashPath(backup, for: match)
        guard (try? fm.destinationOfSymbolicLink(atPath: match.original.path)) == match.external.path,
              match.originalStamp.sameFileAfterMove(try fileStamp(backup)),
              try measure(backup, trashFingerprint: true).signature == entry.trashSignature else {
            throw originalFailure("链接或废纸篓文件已改变 / Link or Trash file changed", match.original)
        }
        return backup
    }

    func validateOriginalForPurge(_ entry: RecoveryEntry, recovery: Recovery) throws
        -> (url: URL, bundle: Int64, disk: Int64?) {
        guard let match = entry.originalMatch else { throw SlimError("缺少原片恢复记录 / Missing original recovery entry") }
        let library = URL(fileURLWithPath: entry.libraryRoot ?? recovery.root)
        try validateLibrary(library)
        guard try identity(library) == (entry.libraryIdentity ?? recovery.identity),
              canonicalFilePath(match.external) == match.external.path,
              try fileStamp(match.external) == match.externalStamp else {
            throw originalFailure("库外素材已改变，无法永久删除 / External file changed; deletion refused", match.external)
        }
        let backup = try validateTrashedOriginal(entry, in: library)
        return (backup, entry.bytes, originalPrivateBytes(backup))
    }

    private func legacyOriginalRecords() throws -> [(URL, OriginalRelinkRecord)] {
        guard fm.fileExists(atPath: originalHistory.path) else { return [] }
        return try fm.contentsOfDirectory(at: originalHistory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { ($0, try JSONDecoder().decode(OriginalRelinkRecord.self, from: Data(contentsOf: $0))) }
            .sorted { $0.1.date > $1.1.date }
    }

    func latestLegacyOriginalRelink() throws -> (date: Date, library: URL)? {
        try legacyOriginalRecords().first.map { ($0.1.date, $0.1.library) }
    }

    @discardableResult
    func undoOriginalRelinks(check: () throws -> Void = {}) throws -> Int {
        let records = try legacyOriginalRecords()
        for (recordURL, record) in records {
            try check()
            try validateLibrary(record.library)
            guard try identity(record.library) == record.identity else {
                throw SlimError("原资源库位置已改变 / Original library changed")
            }
            var pending: [OriginalRelinkRecord.Entry] = []
            for entry in record.entries {
                let match = entry.match
                try validateOriginalParent(match.original, in: record.library)
                let backupLink = try? fm.destinationOfSymbolicLink(atPath: entry.backup.path)
                if let stamp = try? fileStamp(match.original), match.originalStamp.sameFileAfterMove(stamp),
                   backupLink == match.external.path || (try? statAt(entry.backup)) == nil {
                    continue // A recorded swap had not completed, or was already undone.
                }
                guard (try? fm.destinationOfSymbolicLink(atPath: match.original.path)) == match.external.path,
                      let stamp = try? fileStamp(entry.backup), match.originalStamp.sameFileAfterMove(stamp) else {
                    throw originalFailure("链接或废纸篓原片已改变，无法撤销 / Link or Trash backup changed", match.original)
                }
                pending.append(entry)
            }
            for entry in pending.reversed() {
                try check()
                guard (try? fm.destinationOfSymbolicLink(atPath: entry.match.original.path)) == entry.match.external.path,
                      let stamp = try? fileStamp(entry.backup), entry.match.originalStamp.sameFileAfterMove(stamp) else {
                    throw originalFailure("链接或废纸篓原片已改变，无法撤销 / Link or Trash backup changed", entry.match.original)
                }
                try originalSwap(entry.match.original, entry.backup)
            }
            try fm.removeItem(at: recordURL)
            for entry in record.entries where
                (try? fm.destinationOfSymbolicLink(atPath: entry.backup.path)) == entry.match.external.path {
                try? fm.removeItem(at: entry.backup)
            }
            if let folder = record.entries.first?.backup.deletingLastPathComponent().deletingLastPathComponent() {
                for entry in record.entries {
                    let subfolder = entry.backup.deletingLastPathComponent()
                    if (try? fm.contentsOfDirectory(atPath: subfolder.path).isEmpty) == true {
                        try? fm.removeItem(at: subfolder)
                    }
                }
                if (try? fm.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                    try? fm.removeItem(at: folder)
                }
            }
            if !pending.isEmpty { return pending.count }
        }
        return 0
    }
}
