import Foundation

@main struct CoreTests {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("FCPXSlim-tests-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var passes = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw SlimError("FAIL: " + name) }
            passes += 1; print("PASS \(name)")
        }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            var rejected = false
            do { try body() } catch { rejected = true }
            try check(rejected, name)
        }
        func write(_ path: URL, _ size: Int = 32768) throws {
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Non-sparse data, independent of APFS compression.
            var bytes = [UInt8](); bytes.reserveCapacity(size)
            for i in 0..<size { bytes.append(UInt8(truncatingIfNeeded: i * 31 + i / 17)) }
            try Data(bytes).write(to: path)
        }
        let root = base.appendingPathComponent("Fixture.fcpbundle")
        let event = root.appendingPathComponent("Interview <b>& '中文'")
        let db = root.appendingPathComponent("CurrentVersion.flexolibrary")
        let eventDB = event.appendingPathComponent("CurrentVersion.fcpevent")
        let original = event.appendingPathComponent("Original Media/camera.mov")
        let external = base.appendingPathComponent("external.mov")
        try write(db); try write(eventDB); try write(original, 65536); try write(external, 131072)
        let originalData = try Data(contentsOf: original), dbData = try Data(contentsOf: db)
        try write(event.appendingPathComponent("Render Files/cache.mov"))
        try write(event.appendingPathComponent("Transcoded Media/Proxy Media/proxy.mov"))
        try write(event.appendingPathComponent("Analysis Files/optical.dat"))
        try write(root.appendingPathComponent("Shared Items/export.mov"))
        try write(root.appendingPathComponent("__Temp/Render Files/not-a-cache"))
        try fm.createSymbolicLink(at: event.appendingPathComponent("Render Files/external-link"), withDestinationURL: external)
        let core = SlimCore(journal: base.appendingPathComponent("journal/recovery.json"))
        let scanned = try core.scan(root)
        try check(scanned.candidates.count == 3, "exact event/category allowlist")
        try check(scanned.candidates.filter({$0.eligible}).count == 2, "analysis remains read-only")
        let plainSize = try core.measure(external).bytes
        let render = scanned.candidates.first(where: {$0.category == "Render Files"})!
        try check(render.bytes < plainSize, "symbolic link does not follow external media")
        try check(core.measure(root).bytes == scanned.total, "allocated size is deterministic")
        try rejects("ordinary folder rejected") { _ = try core.scan(base) }
        let fake = base.appendingPathComponent("Fake.fcpbundle")
        try fm.createDirectory(at: fake, withIntermediateDirectories: true)
        try rejects("bundle suffix without database rejected") { _ = try core.scan(fake) }
        let linked = base.appendingPathComponent("Link.fcpbundle")
        try fm.createSymbolicLink(at: linked, withDestinationURL: root)
        try rejects("linked library rejected") { _ = try core.scan(linked) }
        let cancellation = Cancellation(); cancellation.cancel()
        try rejects("scan cancellation") { _ = try core.scan(root, cancellation: cancellation) }
        let eligible = Set(scanned.candidates.filter({$0.eligible}).map(\.id))
        try rejects("unknown selection rejected") { _ = try core.clean(scanned, ids: ["forged-id"]) }
        try write(event.appendingPathComponent("Render Files/new.mov"))
        try rejects("stale scan rejected before mutation") { _ = try core.clean(scanned, ids: eligible) }
        try check(fm.fileExists(atPath: render.path), "stale scan leaves caches intact")
        let hardEvent = root.appendingPathComponent("HardLinks")
        try write(hardEvent.appendingPathComponent("CurrentVersion.fcpevent"))
        try fm.createDirectory(at: hardEvent.appendingPathComponent("Render Files"), withIntermediateDirectories: true)
        try fm.linkItem(at: external, to: hardEvent.appendingPathComponent("Render Files/hard.mov"))
        let withHardLinks = try core.scan(root)
        try check(withHardLinks.candidates.first(where: {$0.event == "HardLinks"})?.eligible == false, "hard-linked cache retained")
        let hardBytes = try core.measure(hardEvent.appendingPathComponent("Render Files")).bytes
        try fm.linkItem(at: external, to: hardEvent.appendingPathComponent("Render Files/hard2.mov"))
        let dedupBytes = try core.measure(hardEvent.appendingPathComponent("Render Files")).bytes
        try check(dedupBytes - hardBytes < plainSize, "hard-link size is deduplicated")
        let protectedEvent = root.appendingPathComponent("Protected")
        try write(protectedEvent.appendingPathComponent("CurrentVersion.fcpevent"))
        try write(protectedEvent.appendingPathComponent("Render Files/Original Media/camera.mov"))
        try rejects("protected nested media stops scan") { _ = try core.scan(root) }
        // Remove only the intentionally malformed test event, created above.
        try fm.removeItem(at: protectedEvent)
        let fresh = try core.scan(root)
        let freshIDs = Set(fresh.candidates.filter({$0.eligible}).map(\.id))
        let recovery = try core.clean(fresh, ids: freshIDs)
        try check(recovery.entries.count == 2, "system Trash records both returned destinations")
        try check(recovery.entries.allSatisfy({$0.trash != nil && fm.fileExists(atPath: $0.trash!)}), "files actually exist in system Trash")
        try check(!fm.fileExists(atPath: render.path), "cache is removed from library")
        try check(Data(contentsOf: original) == originalData && Data(contentsOf: db) == dbData, "original media and library database unchanged")
        try check(Data(contentsOf: external).count == 131072, "external media unchanged")
        try rejects("stale second cleanup rejected") { _ = try core.clean(fresh, ids: freshIDs) }
        let conflict = URL(fileURLWithPath: recovery.entries[0].original)
        try fm.createDirectory(at: conflict, withIntermediateDirectories: true)
        try rejects("restore does not overwrite regenerated cache") { try core.restore() }
        try check(recovery.entries.allSatisfy({fm.fileExists(atPath: $0.trash!)}), "conflict preflight leaves all Trash entries intact")
        try fm.removeItem(at: conflict)
        let restarted = SlimCore(journal: core.journal)
        try restarted.restore()
        try check(recovery.entries.allSatisfy({fm.fileExists(atPath: $0.original)}), "restore after app restart returns original structure")
        try check(!restarted.hasUnrestored(), "restored journal persists")
        try check(Data(contentsOf: original) == originalData && Data(contentsOf: db) == dbData, "originals unchanged after full round trip")
        let firstBatch = try core.scan(root)
        let firstID = firstBatch.candidates.first(where: {$0.eligible})!.id
        let first = try core.clean(firstBatch, ids: [firstID])
        let nextBatch = try core.scan(root)
        let nextID = nextBatch.candidates.first(where: {$0.eligible})!.id
        let second = try core.clean(nextBatch, ids: [nextID])
        try check(try core.load()?.id == second.id, "latest cleanup is restored first")
        try core.restore()
        try check(try core.load()?.id == first.id, "earlier recovery record survives a later cleanup")
        try core.restore()
        try check(!core.hasUnrestored(), "multiple cleanups can be restored in reverse order")
        let purgeScan = try core.scan(root)
        let purgeID = purgeScan.candidates.first(where: {$0.eligible})!.id
        let purgeRecord = try core.clean(purgeScan, ids: [purgeID])
        try check(purgeRecord.entries.allSatisfy({$0.trashSignature != nil}), "purge records post-Trash fingerprints")
        try rejects("purge requires the exact confirmed transaction") { _ = try core.emptyLatest(expectedID: "wrong-transaction") }
        var forged = purgeRecord
        forged.entries[0].trash = event.appendingPathComponent("Original Media").path
        forged.entries[0].trashSignature = try core.measure(URL(fileURLWithPath: forged.entries[0].trash!)).signature
        try core.save(forged)
        try rejects("purge refuses paths outside the system Trash") { _ = try core.emptyLatest(expectedID: purgeRecord.id) }
        try core.save(purgeRecord)
        var wrongFingerprint = purgeRecord
        wrongFingerprint.entries[0].trashSignature = "changed-fingerprint"
        try core.save(wrongFingerprint)
        try rejects("purge refuses altered Trash contents") { _ = try core.emptyLatest(expectedID: purgeRecord.id) }
        try core.save(purgeRecord)
        let unrelated = base.appendingPathComponent("Unrelated-" + UUID().uuidString)
        try write(unrelated.appendingPathComponent("unrelated.txt"))
        var unrelatedTrash: NSURL?
        try fm.trashItem(at: unrelated, resultingItemURL: &unrelatedTrash)
        // Finder may update the top-level Trash item's metadata asynchronously.
        // This changes ctime without changing the cache, and must not block deletion.
        let purgeURL = URL(fileURLWithPath: purgeRecord.entries[0].trash!)
        let beforeMetadata = try core.statAt(purgeURL)
        Thread.sleep(forTimeInterval: 0.02)
        try fm.setAttributes([.posixPermissions: NSNumber(value: beforeMetadata.st_mode & 0o7777)], ofItemAtPath: purgeURL.path)
        let afterMetadata = try core.statAt(purgeURL)
        try check(beforeMetadata.st_ctimespec.tv_sec != afterMetadata.st_ctimespec.tv_sec || beforeMetadata.st_ctimespec.tv_nsec != afterMetadata.st_ctimespec.tv_nsec, "reproduce system metadata update changing Trash root ctime")
        let deletedBytes = try SlimCore(journal: core.journal).emptyLatest(expectedID: purgeRecord.id)
        try check(deletedBytes == purgeRecord.entries[0].bytes, "scoped purge reports only recorded bytes")
        try check(!fm.fileExists(atPath: purgeRecord.entries[0].trash!), "confirmed generated test cache is permanently removed")
        try check(fm.fileExists(atPath: unrelatedTrash!.path!), "unrelated system Trash item is untouched")
        try check(Data(contentsOf: original) == originalData && Data(contentsOf: db) == dbData, "purge retains originals and database")
        try check(Data(contentsOf: external).count == 131072, "purge never follows links to external media")
        try check(!core.hasUnrestored(), "permanently deleted entries are no longer recoverable")
        try rejects("purged transaction cannot be restored") { try core.restore() }
        try fm.moveItem(at: unrelatedTrash! as URL, to: unrelated)
        // Recreate only the synthetic cache deleted by this test, for UI fixtures.
        try write(event.appendingPathComponent("Render Files/cache.mov"))
        try write(event.appendingPathComponent("Render Files/new.mov"))
        try fm.createSymbolicLink(at: event.appendingPathComponent("Render Files/external-link"), withDestinationURL: external)
        // Existing v1 journals need a renewed, explicit review after metadata drift.
        let legacyScan = try core.scan(root)
        let legacyID = legacyScan.candidates.first(where: {$0.eligible})!.id
        var legacyRecord = try core.clean(legacyScan, ids: [legacyID])
        let legacyURL = URL(fileURLWithPath: legacyRecord.entries[0].trash!)
        legacyRecord.entries[0].trashSignature = try core.measure(legacyURL, protect: true).signature
        try core.save(legacyRecord)
        Thread.sleep(forTimeInterval: 0.02)
        let legacyStat = try core.statAt(legacyURL)
        try fm.setAttributes([.posixPermissions: NSNumber(value: legacyStat.st_mode & 0o7777)], ofItemAtPath: legacyURL.path)
        try rejects("old changed fingerprint cannot be deleted without renewed review") { _ = try core.emptyLatest(expectedID: legacyRecord.id) }
        let legacyReview = try core.reviewEmpty(expectedID: legacyRecord.id)
        try check(legacyReview.refreshedLegacy && legacyReview.legacySignatures[legacyURL.path] != nil, "old journal explicitly requests review of current Trash paths and size")
        try check(try core.load()?.entries[0].trashSignature == legacyRecord.entries[0].trashSignature, "review does not silently replace the saved old fingerprint")
        try write(legacyURL.appendingPathComponent("changed-after-review.cache"))
        try rejects("legacy deletion refuses actual changes after review") { _ = try core.emptyLatest(expectedID: legacyRecord.id, reviewedLegacySignatures: legacyReview.legacySignatures) }
        try check(fm.fileExists(atPath: legacyURL.path), "failed legacy recheck leaves the whole cache intact")
        let secondReview = try core.reviewEmpty(expectedID: legacyRecord.id)
        let legacyBytes = try core.emptyLatest(expectedID: legacyRecord.id, reviewedLegacySignatures: secondReview.legacySignatures)
        try check(!fm.fileExists(atPath: legacyURL.path), "reviewed legacy test cache is actually permanently removed")
        try check(legacyBytes == secondReview.bytes, "legacy deletion reports the reviewed current size")
        try write(event.appendingPathComponent("Render Files/cache.mov"))
        try write(event.appendingPathComponent("Render Files/new.mov"))
        if !fm.fileExists(atPath: event.appendingPathComponent("Render Files/external-link").path) {
            try fm.createSymbolicLink(at: event.appendingPathComponent("Render Files/external-link"), withDestinationURL: external)
        }
        let changedScan = try core.scan(root)
        let changedID = changedScan.candidates.first(where: {$0.eligible})!.id
        var changedRecord = try core.clean(changedScan, ids: [changedID])
        let changedURL = URL(fileURLWithPath: changedRecord.entries[0].trash!)
        try write(changedURL.appendingPathComponent("real-change.cache"))
        try rejects("v2 review refuses actual cache changes") { _ = try core.reviewEmpty(expectedID: changedRecord.id) }
        try rejects("v2 permanent deletion refuses actual cache changes") { _ = try core.emptyLatest(expectedID: changedRecord.id) }
        try check(fm.fileExists(atPath: changedURL.path), "changed v2 cache remains intact")
        // Reversibly return only this generated test cache, preserving its change.
        try fm.moveItem(at: changedURL, to: URL(fileURLWithPath: changedRecord.entries[0].original))
        changedRecord.entries[0].restored = true
        try core.save(changedRecord)
        let folder = base.appendingPathComponent("video 999")
        func makeLibrary(_ relative: String) throws -> URL {
            let library = folder.appendingPathComponent(relative)
            try write(library.appendingPathComponent("CurrentVersion.flexolibrary"))
            try write(library.appendingPathComponent("Event/CurrentVersion.fcpevent"))
            try write(library.appendingPathComponent("Event/Original Media/source.mov"))
            try write(library.appendingPathComponent("Event/Render Files/cache.mov"))
            return library
        }
        let libraryA = try makeLibrary("A/Same.fcpbundle"), libraryB = try makeLibrary("B/Same.fcpbundle")
        let libraryC = try makeLibrary("Unselected.fcpbundle")
        try fm.createDirectory(at: folder.appendingPathComponent("NotALibrary.fcpbundle"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("linked-library.fcpbundle"), withDestinationURL: root)
        let discovered = try core.discoverLibraries(folder)
        try check(Set(discovered.libraries.map(\.path)) == Set([libraryA.path, libraryB.path, libraryC.path]), "folder discovery finds nested libraries and skips invalid bundles and symlinks")
        try check(discovered.unreadable.isEmpty, "discovery reports no unreadable test directories")
        let emptyFolder = base.appendingPathComponent("Empty folder")
        try fm.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        try check(try core.discoverLibraries(emptyFolder).libraries.isEmpty, "ordinary folder without FCP libraries reports no match")
        let stopDiscovery = Cancellation(); stopDiscovery.cancel()
        try rejects("folder discovery can be cancelled") { _ = try core.discoverLibraries(folder, cancellation: stopDiscovery) }
        let batchCore = SlimCore(journal: base.appendingPathComponent("batch-journal/recovery.json"))
        var scanA = try batchCore.scan(libraryA), scanB = try batchCore.scan(libraryB)
        try rejects("batch rejects duplicate cache paths before any movement") {
            let ids = Set(scanA.candidates.filter(\.eligible).map(\.id))
            _ = try batchCore.cleanBatch([(scanA, ids), (scanA, ids)])
        }
        let cacheB = libraryB.appendingPathComponent("Event/Render Files/change.cache")
        try write(cacheB)
        try rejects("batch validates all libraries before moving the first cache") {
            _ = try batchCore.cleanBatch([(scanA, Set(scanA.candidates.filter(\.eligible).map(\.id))), (scanB, Set(scanB.candidates.filter(\.eligible).map(\.id)))])
        }
        try check(fm.fileExists(atPath: libraryA.appendingPathComponent("Event/Render Files/cache.mov").path), "stale second library leaves first library untouched")
        scanB = try batchCore.scan(libraryB)
        let batch = try batchCore.cleanBatch([(scanA, Set(scanA.candidates.filter(\.eligible).map(\.id))), (scanB, Set(scanB.candidates.filter(\.eligible).map(\.id)))])
        try check(batch.entries.count==2 && Set(batch.entries.compactMap(\.libraryRoot))==Set([libraryA.path,libraryB.path]), "one recovery transaction records each selected library's real location")
        try check(fm.fileExists(atPath: libraryC.appendingPathComponent("Event/Render Files/cache.mov").path), "batch cleanup leaves unselected library intact")
        let originalA = try Data(contentsOf: libraryA.appendingPathComponent("Event/Original Media/source.mov"))
        let conflictB = libraryB.appendingPathComponent("Event/Render Files")
        try fm.createDirectory(at: conflictB, withIntermediateDirectories: true)
        try rejects("multi library restore preflights all conflicts") { try batchCore.restore() }
        try check(batch.entries.allSatisfy({fm.fileExists(atPath:$0.trash!)}), "multi library restore conflict leaves every Trash item intact")
        try fm.removeItem(at: conflictB)
        try SlimCore(journal: batchCore.journal).restore()
        try check(batch.entries.allSatisfy({fm.fileExists(atPath:$0.original)}), "restart restores both libraries to their respective original locations")
        try check(try Data(contentsOf: libraryA.appendingPathComponent("Event/Original Media/source.mov")) == originalA, "multi library round trip preserves original media")
        scanA = try batchCore.scan(libraryA); scanB = try batchCore.scan(libraryB)
        let purgeBatch = try batchCore.cleanBatch([(scanA,Set(scanA.candidates.filter(\.eligible).map(\.id))),(scanB,Set(scanB.candidates.filter(\.eligible).map(\.id)))])
        _ = try batchCore.emptyLatest(expectedID: purgeBatch.id)
        try check(purgeBatch.entries.allSatisfy({!fm.fileExists(atPath:$0.trash!)}), "confirmed synthetic multi library batch is actually permanently removed")
        try check(fm.fileExists(atPath: libraryC.appendingPathComponent("Event/Render Files/cache.mov").path), "multi library purge retains unselected library")
        // Direct deletion must not consume older pending cleanups.
        let olderLibrary = try makeLibrary("Older.fcpbundle")
        let directLibrary = try makeLibrary("Direct.fcpbundle")
        let directCore = SlimCore(journal: base.appendingPathComponent("direct-journal/recovery.json"))
        let olderScan = try directCore.scan(olderLibrary)
        let older = try directCore.clean(olderScan, ids: Set(olderScan.candidates.filter(\.eligible).map(\.id)))
        let directScan = try directCore.scan(directLibrary)
        let directIDs = Set(directScan.candidates.filter(\.eligible).map(\.id))
        let directOriginal = directLibrary.appendingPathComponent("Event/Original Media/source.mov")
        let directDatabase = directLibrary.appendingPathComponent("CurrentVersion.flexolibrary")
        let beforeOriginal = try Data(contentsOf: directOriginal), beforeDatabase = try Data(contentsOf: directDatabase)
        try rejects("direct deletion rejects stale scan before touching selected caches") {
            try write(directLibrary.appendingPathComponent("Event/Render Files/changed.cache"))
            _ = try directCore.permanentlyCleanBatch([(directScan, directIDs)])
        }
        try check(fm.fileExists(atPath: directScan.candidates[0].path), "failed direct preflight leaves selected cache intact")
        let directFresh = try directCore.scan(directLibrary)
        var movedBeforeDeletion = false
        let directDeletedBytes = try directCore.permanentlyCleanBatch([(directFresh, Set(directFresh.candidates.filter(\.eligible).map(\.id)))], moved: {
            if let record = try? directCore.load() {
                movedBeforeDeletion = record.root == directLibrary.path && record.entries.allSatisfy { $0.purged != true && $0.trash != nil && fm.fileExists(atPath: $0.trash!) }
            }
        })
        try check(movedBeforeDeletion, "direct deletion announces step two only after all selected caches reach Trash")
        try check(directDeletedBytes > 0 && !fm.fileExists(atPath: directFresh.candidates[0].path), "direct deletion actually removes selected cache and returns measured bytes")
        let history = directCore.journal.deletingLastPathComponent().appendingPathComponent("transactions")
        let records = try fm.contentsOfDirectory(at: history, includingPropertiesForKeys: nil).map { try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: $0)) }
        let directRecord = records.first { $0.root == directLibrary.path }!
        try check(directRecord.entries.allSatisfy { $0.purged == true && !fm.fileExists(atPath: $0.trash!) }, "direct deletion persists purged state and leaves no selected files in Trash")
        try check(older.entries.allSatisfy { fm.fileExists(atPath: $0.trash!) } && directCore.load()?.id == older.id, "direct deletion leaves older pending cleanup untouched and recoverable")
        try check(Data(contentsOf: directOriginal) == beforeOriginal && Data(contentsOf: directDatabase) == beforeDatabase, "direct deletion preserves original media and library database")
        try directCore.restore()
        print("\(passes) checks passed. Fixture retained at \(root.path)")
        try root.path.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("latest-fixture.txt"), atomically: true, encoding: .utf8)
    }
}
