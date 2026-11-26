import Foundation
import Darwin

@main struct OriginalRelinkTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent("OriginalRelink-" + UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Fixture.fcpbundle", isDirectory: true)
        let event = library.appendingPathComponent("Event", isDirectory: true)
        let originals = event.appendingPathComponent("Original Media", isDirectory: true)
        let external = root.appendingPathComponent("Footage", isDirectory: true)
        let core = SlimCore(journal: root.appendingPathComponent("journal/recovery.json"))
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw SlimError(message) }
        }
        func write(_ value: String, _ folder: URL, _ name: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data(value.utf8).write(to: url)
            return url
        }

        _ = try write("library", library, "CurrentVersion.flexolibrary")
        _ = try write("event", event, "CurrentVersion.fcpevent")
        let source = try write("clone content", external, "原片.MOV")
        let original = originals.appendingPathComponent("更名.mov")
        try require(clonefile(source.path, original.path, 0) == 0, "APFS test clone failed")
        let independentSource = try write("independent content", external, "independent.mov")
        let independent = try write("independent content", originals, "independent.mov")
        _ = try write("ABCD", originals, "same-name.mov")
        _ = try write("WXYZ", external, "same-name.mov")
        _ = try write("ambiguous", originals, "ambiguous.mov")
        _ = try write("ambiguous", external, "take1.mov")
        _ = try write("ambiguous", external, "take2.mov")
        _ = try write("ambiguous", external, "take3.mov")
        _ = try write("only in library", originals, "unique.mov")
        let alreadyLinked = originals.appendingPathComponent("already-linked.mov")
        try fm.createSymbolicLink(at: alreadyLinked, withDestinationURL: source)
        let nestedLibrary = external.appendingPathComponent("Another.fcpbundle")
        try fm.createDirectory(at: nestedLibrary, withIntermediateDirectories: true)
        _ = try write("only in library", nestedLibrary, "do-not-use.mov")

        let render = event.appendingPathComponent("Render Files", isDirectory: true)
        try fm.createDirectory(at: render, withIntermediateDirectories: false)
        let cache = try write("rebuildable render", render, "cache.mov")

        var progress: [(Int64, Int64)] = []
        let first = try core.scan(library, comparisonProgress: { read, total in progress.append((read, total)) })
        try require(progress.first?.0 == 0 && progress.first?.1 ?? 0 > 0, "Comparison did not report its read plan")
        try require(progress.last?.0 == progress.last?.1, "Comparison left unread ambiguous candidates in its final total")
        let duplicateCandidates = first.candidates.filter { $0.originalMatch != nil }
        try require(duplicateCandidates.count == 2, "Only unique byte matches should be presented automatically")
        try require(duplicateCandidates.allSatisfy { $0.eligible && $0.category == "Duplicate Media" }, "Duplicates were not eligible in details")
        try require(duplicateCandidates.first(where: {$0.path == original.path})?.originalMatch?.external.path == source.path, "Renamed source not matched")
        try require(duplicateCandidates.first(where: {$0.path == original.path})?.originalMatch?.privateBytes == 0, "Clone counted as free space")
        try require((duplicateCandidates.first(where: {$0.path == independent.path})?.originalMatch?.privateBytes ?? 0) > 0, "Independent storage was not counted")
        try require(core.regular(original), "Scan changed the original")
        try Data("replacement content".utf8).write(to: independentSource)
        do {
            _ = try core.clean(first, ids: Set(first.candidates.map(\.id)))
            throw SlimError("A changed source was accepted")
        } catch let error as SlimError {
            try require(error.message.contains("Media or path changed"), error.message)
        }
        try require(core.regular(original) && core.regular(independent) && core.regular(cache), "Failed preflight changed the library")
        try Data("independent content".utf8).write(to: independentSource)

        let selected = try core.scan(library)
        let selection = Set(selected.candidates.filter { $0.path != independent.path }.map(\.id))
        let recovery = try core.clean(selected, ids: selection)
        try require(recovery.entries.count == 2 && recovery.entries.contains { $0.originalMatch != nil }, "Missing mixed recovery transaction")
        try require(try fm.destinationOfSymbolicLink(atPath: original.path) == source.path, "Incorrect external target")
        try require(try Data(contentsOf: original) == Data(contentsOf: source), "Link target is unreadable")
        try require(core.regular(independent), "Unchecked duplicate was modified")
        try require(!fm.fileExists(atPath: cache.path), "Selected cache was not removed")
        try require(try core.scan(library).candidates.filter { $0.originalMatch != nil }.count == 1, "Existing link was scanned again")
        let emptyReview = try core.reviewEmpty(expectedID: recovery.id)
        let cacheBytes = recovery.entries.first { $0.originalMatch == nil }!.bytes
        try require(emptyReview.estimatedDiskBytes == cacheBytes, "Review treated a clone as released disk space")

        let moved = external.appendingPathComponent("moved-original.mov")
        try fm.moveItem(at: source, to: moved)
        do {
            _ = try core.emptyLatest(expectedID: recovery.id)
            throw SlimError("An unavailable external file was accepted")
        } catch {
            try require(recovery.entries.allSatisfy { fm.fileExists(atPath: $0.trash!) }, "Purge preflight removed part of the batch")
        }
        try SlimCore(journal: core.journal).restore()
        try require(core.regular(original) && core.regular(independent) && core.regular(cache), "Combined undo did not restore originals and cache")
        try require(try Data(contentsOf: original) == Data("clone content".utf8), "Undo altered the original")
        try fm.moveItem(at: moved, to: source)

        let permanent = try core.scan(library)
        let permanentIDs = Set(permanent.candidates.filter { $0.path != independent.path }.map(\.id))
        let purgedBytes = try core.permanentlyCleanBatch([(scan: permanent, ids: permanentIDs)])
        try require(purgedBytes == cacheBytes, "Permanent cleanup claimed cloned media freed storage")
        try require(try fm.destinationOfSymbolicLink(atPath: original.path) == source.path, "Permanent deletion lost the media link")
        try require(try Data(contentsOf: source) == Data("clone content".utf8), "Permanent deletion changed the external source")
        try require(try core.load()?.entries.allSatisfy { $0.purged == true && !fm.fileExists(atPath: $0.trash!) } == true,
                    "Permanent cleanup left selected files recoverable")
        try require(core.regular(independent), "Permanent deletion modified an unchecked duplicate")
        print("Duplicate media tests passed. Verified automatic matching, selection, combined undo, stale-source protection and permanent deletion.")
    }
}
