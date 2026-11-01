import Core
import Downloads
import Foundation
import GRDB
import Testing

@testable import Library

private let dpid = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
private let otherDPlaylist = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
private let dprofile = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
private let otherDProfile = UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!

private func dkey(profile p: UUID = dprofile, playlist: UUID = dpid, kind: ContentKind = .movie,
                  provider: String = "m1") -> DownloadKey {
    DownloadKey(profileID: p, playlistID: playlist, kind: kind, providerID: provider)
}

private func snap(_ title: String = "Film", container: String? = "mkv", locatorID: String = "m1") -> DownloadSnapshot {
    DownloadSnapshot(title: title, year: 2001, container: container,
                     locator: .xtream(kind: .movie, streamID: locatorID, container: container ?? "mp4"),
                     expectedBytes: 100, addedAt: Date(timeIntervalSince1970: 5000))
}

private struct DFixture {
    let store: DownloadStore
    let db: AppDatabase
    let library: LibraryStore
    let directory: URL
    let scratch: URL
}

private func makeDFixture() throws -> DFixture {
    let db = try AppDatabase.inMemory()
    let library = LibraryStore(db: db)
    let created = Date(timeIntervalSince1970: 1000)
    try library.upsertPlaylist(Playlist(id: dpid, name: "A", kind: .xtream, createdAt: created))
    try library.upsertPlaylist(Playlist(id: otherDPlaylist, name: "B", kind: .m3u, createdAt: created))
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("download-tests-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("store", isDirectory: true)
    let scratch = root.appendingPathComponent("scratch", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return DFixture(store: DownloadStore(db: db, directory: directory), db: db, library: library,
                    directory: directory, scratch: scratch)
}

private func cleanUp(_ f: DFixture) {
    try? FileManager.default.removeItem(at: f.directory.deletingLastPathComponent())
}

private func tempFile(_ f: DFixture, bytes: Int) throws -> URL {
    let url = f.scratch.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 7, count: bytes).write(to: url)
    return url
}

private func filesUnder(_ url: URL) -> [String] {
    guard let e = FileManager.default.enumerator(atPath: url.path) else { return [] }
    return (e.allObjects as? [String]) ?? []
}

@Test func insertAndListPerProfile() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    let stored = try f.store.insert(snap(), key: dkey())
    #expect(stored.state == .queued)
    #expect(stored.fileURL == nil)
    // Nyckelkonflikt ger den befintliga raden.
    try f.store.updateState(.downloading(progress: 0.5), bytesWritten: 50, for: dkey())
    let again = try f.store.insert(snap("Annan titel"), key: dkey())
    #expect(again.snapshot.title == "Film")
    #expect(again.state == .downloading(progress: 0.5))

    try f.store.insert(snap(), key: dkey(playlist: otherDPlaylist))
    #expect(try f.store.list(profileID: dprofile, playlistID: nil).count == 2)
    #expect(try f.store.list(profileID: dprofile, playlistID: dpid).map(\.key) == [dkey()])
    #expect(try f.store.list(profileID: otherDProfile, playlistID: nil).isEmpty)
    #expect(try f.store.download(for: dkey(profile: otherDProfile)) == nil)
}

@Test func listAllReturnsRowsOfEveryProfile() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    try f.store.insert(snap(), key: dkey(profile: otherDProfile, provider: "m2"))
    #expect(try f.store.listAll().count == 2)
    #expect(try f.store.list(profileID: dprofile, playlistID: nil).count == 1)
}

@Test func snapshotSurvivesCatalogReplace() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    let movie = Movie(providerID: "m1", title: "Film", locator: .xtream(kind: .movie, streamID: "m1", container: "mkv"))
    try f.library.replaceCatalog(ProviderCatalog(movies: [movie]), playlistID: dpid, now: Date(timeIntervalSince1970: 1))
    try f.store.insert(snap(), key: dkey())
    try f.library.replaceCatalog(ProviderCatalog(movies: []), playlistID: dpid, now: Date(timeIntervalSince1970: 2))
    let row = try #require(try f.store.download(for: dkey()))
    #expect(row.snapshot.title == "Film")
}

@Test func removingPlaylistCascadesRows() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    try f.library.deletePlaylist(dpid)
    #expect(try f.store.list(profileID: dprofile, playlistID: nil).isEmpty)
}

@Test func purgeOrphansRemovesFilesWithoutRow() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    try f.store.setResumeData(Data([1, 2, 3]), for: dkey())
    try f.store.insert(snap(), key: dkey(provider: "m2"))
    try f.store.setResumeData(Data([4]), for: dkey(provider: "m2"))
    try f.library.deletePlaylist(dpid)
    try f.store.purgeOrphans()
    #expect(filesUnder(f.directory).isEmpty)
}

@Test func purgeKeepsFilesWithRow() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    try f.store.setResumeData(Data([1]), for: dkey())
    try f.store.purgeOrphans()
    #expect(try f.store.resumeData(for: dkey()) == Data([1]))
}

@Test func purgeMarksMissingFileAsFailedStorage() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    let done = try f.store.completeMoving(from: try tempFile(f, bytes: 10), for: dkey(), expectedMinBytes: 5)
    try FileManager.default.removeItem(at: try #require(done.fileURL))
    try f.store.purgeOrphans()
    #expect(try f.store.download(for: dkey())?.state == .failed(.storage))
    #expect(try f.store.download(for: dkey())?.fileURL == nil)
}

@Test func completeMovingRejectsTooSmallFile() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    let temp = try tempFile(f, bytes: 10)
    #expect(throws: DownloadStoreError.fileTooSmall(actual: 10, required: 1000)) {
        try f.store.completeMoving(from: temp, for: dkey(), expectedMinBytes: 1000)
    }
    #expect(!FileManager.default.fileExists(atPath: temp.path))
    let row = try #require(try f.store.download(for: dkey()))
    #expect(row.state != .completed)
    #expect(row.fileURL == nil)
    #expect(filesUnder(f.directory).allSatisfy { !$0.hasSuffix(".mkv") })
}

@Test func completeMovingRejectsEmptyFileEvenWithZeroMinimum() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    let temp = try tempFile(f, bytes: 0)
    #expect(throws: DownloadStoreError.self) {
        try f.store.completeMoving(from: temp, for: dkey(), expectedMinBytes: 0)
    }
    #expect(try f.store.download(for: dkey())?.state != .completed)
}

@Test func completeMovingWithoutRowDeletesTempAndThrows() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    let temp = try tempFile(f, bytes: 10)
    #expect(throws: DownloadStoreError.notFound) {
        try f.store.completeMoving(from: temp, for: dkey(), expectedMinBytes: 1)
    }
    #expect(!FileManager.default.fileExists(atPath: temp.path))
    #expect(filesUnder(f.directory).isEmpty)
}

@Test func completeMovingIsAtomicAndRelative() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    let temp = try tempFile(f, bytes: 64)
    let done = try f.store.completeMoving(from: temp, for: dkey(), expectedMinBytes: 64)
    #expect(done.state == .completed)
    #expect(done.bytesWritten == 64)
    #expect(!FileManager.default.fileExists(atPath: temp.path))
    let url = try #require(done.fileURL)
    #expect(try Data(contentsOf: url).count == 64)
    #expect(url.lastPathComponent == "media.mkv")
    // Databasen håller en relativ sökväg som byggts av DownloadPaths.
    let stored: String? = try f.db.writer.read { try String.fetchOne($0, sql: "SELECT relativePath FROM download") }
    let relative = try #require(stored)
    #expect(!relative.hasPrefix("/"))
    #expect(relative == DownloadPaths.relativeDirectory(for: dkey()) + "/media.mkv")
    #expect(url.path == f.directory.appendingPathComponent(relative).path)
    #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}

@Test func completeMovingReplacesExistingFile() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    try f.store.completeMoving(from: try tempFile(f, bytes: 10), for: dkey(), expectedMinBytes: 1)
    let second = try f.store.completeMoving(from: try tempFile(f, bytes: 20), for: dkey(), expectedMinBytes: 1)
    #expect(second.bytesWritten == 20)
    #expect(try Data(contentsOf: try #require(second.fileURL)).count == 20)
}

@Test func updateStateCannotMarkCompletedOrRegressCompleted() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    #expect(throws: DownloadStoreError.completionRequiresFile) {
        try f.store.updateState(.completed, bytesWritten: 1, for: dkey())
    }
    try f.store.completeMoving(from: try tempFile(f, bytes: 10), for: dkey(), expectedMinBytes: 1)
    try f.store.updateState(.downloading(progress: 0.1), bytesWritten: 1, for: dkey())
    #expect(try f.store.download(for: dkey())?.state == .completed)
}

@Test func removeDeletesFilesAndArtwork() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    try f.store.completeMoving(from: try tempFile(f, bytes: 10), for: dkey(), expectedMinBytes: 1)
    try f.store.saveArtwork(poster: Data([1]), backdrop: Data([2]), still: nil, for: dkey())
    try f.store.setResumeData(Data([3]), for: dkey())
    let art = try #require(try f.store.download(for: dkey())?.artworkURLs)
    #expect(art.poster != nil)
    #expect(art.backdrop != nil)
    #expect(art.still == nil)
    try f.store.remove(dkey())
    #expect(try f.store.download(for: dkey()) == nil)
    #expect(try f.store.resumeData(for: dkey()) == nil)
    #expect(!filesUnder(f.directory).contains { $0.hasSuffix("media.mkv") || $0.hasSuffix("poster.img") })
    // Att ta bort något som inte finns är inget fel.
    try f.store.remove(dkey())
}

@Test func resumeDataRoundTripsAndClears() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    #expect(try f.store.resumeData(for: dkey()) == nil)
    try f.store.setResumeData(Data([9, 9]), for: dkey())
    #expect(try f.store.resumeData(for: dkey()) == Data([9, 9]))
    try f.store.setResumeData(nil, for: dkey())
    #expect(try f.store.resumeData(for: dkey()) == nil)
    #expect(throws: DownloadStoreError.notFound) {
        try f.store.setResumeData(Data([1]), for: dkey(provider: "saknas"))
    }
}

@Test func pathsCannotEscapeDirectory() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    let evil = dkey(provider: "../x")
    try f.store.insert(snap(), key: evil)
    try f.store.completeMoving(from: try tempFile(f, bytes: 10), for: evil, expectedMinBytes: 1)
    try f.store.setResumeData(Data([1]), for: evil)
    try f.store.saveArtwork(poster: Data([1]), backdrop: nil, still: nil, for: evil)
    let root = f.directory.deletingLastPathComponent().standardizedFileURL.path
    for name in filesUnder(f.directory.deletingLastPathComponent()) where !name.hasPrefix("scratch") {
        #expect(name.hasPrefix("store/"))
        #expect(!name.contains(".."))
    }
    let url = try #require(try f.store.download(for: evil)?.fileURL)
    #expect(url.standardizedFileURL.path.hasPrefix(f.directory.standardizedFileURL.path + "/"))
    #expect(url.standardizedFileURL.path.hasPrefix(root))
    #expect(!FileManager.default.fileExists(atPath: f.directory.deletingLastPathComponent()
        .appendingPathComponent("x").path))
}

@Test func snapshotJSONNeverContainsCredentialsOrAbsoluteURLWithSecrets() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    let template = DownloadSnapshot(title: "T", locator: .template("{server}/{username}/{password}/x.mkv"))
    try f.store.insert(template, key: dkey(provider: "t"))
    let jsons: [String] = try f.db.writer.read { try String.fetchAll($0, sql: "SELECT snapshotJSON FROM download") }
    #expect(jsons.count == 2)
    for json in jsons {
        #expect(!json.contains("http://"))
        #expect(!json.contains("https://"))
        #expect(!json.lowercased().contains("secret"))
        let decoded = try JSONDecoder.snapshotDecoder.decode(DownloadSnapshot.self, from: Data(json.utf8))
        switch decoded.locator {
        case .xtream(_, let streamID, _): #expect(streamID == "m1")
        case .template(let t): #expect(t.contains("{password}"))
        }
    }
}

private extension JSONDecoder {
    static var snapshotDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

@Test func totalBytesPerProfile() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    #expect(try f.store.totalBytes(profileID: dprofile) == 0)
    try f.store.insert(snap(), key: dkey())
    try f.store.insert(snap(), key: dkey(provider: "m2"))
    try f.store.insert(snap(), key: dkey(profile: otherDProfile))
    try f.store.updateState(.downloading(progress: 0.1), bytesWritten: 100, for: dkey())
    try f.store.updateState(.paused(.user), bytesWritten: 250, for: dkey(provider: "m2"))
    try f.store.updateState(.downloading(progress: 0.1), bytesWritten: 7, for: dkey(profile: otherDProfile))
    #expect(try f.store.totalBytes(profileID: dprofile) == 350)
    #expect(try f.store.totalBytes(profileID: otherDProfile) == 7)
}

@Test func stateRoundTripsAllCases() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    var cases: [DownloadState] = [
        .queued, .downloading(progress: 0.25),
        .paused(.user), .paused(.connectionNeeded), .paused(.waitingForWifi), .paused(.lowDiskSpace),
    ]
    for failure in [DownloadFailure.badStatus, .badContent, .noSpace, .storage, .expired, .network, .unknown] {
        cases.append(.failed(failure))
    }
    for (i, state) in cases.enumerated() {
        let k = dkey(provider: "s\(i)")
        try f.store.insert(snap(), key: k)
        try f.store.updateState(state, bytesWritten: Int64(i), for: k)
        let row = try #require(try f.store.download(for: k))
        #expect(row.state == state)
        #expect(row.bytesWritten == Int64(i))
    }
    let k = dkey(provider: "done")
    try f.store.insert(snap(), key: k)
    #expect(try f.store.completeMoving(from: try tempFile(f, bytes: 3), for: k, expectedMinBytes: 1).state == .completed)
    #expect(try f.store.download(for: k)?.state == .completed)
}

@Test func episodeKeyKeepsSeriesInSnapshot() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    let k = dkey(kind: .series, provider: "e1")
    let s = DownloadSnapshot(title: "Avsnitt", season: 1, episode: 2, container: "mp4", seriesProviderID: "s1",
                             seriesTitle: "Serie", locator: .xtream(kind: .series, streamID: "e1", container: "mp4"))
    let stored = try f.store.insert(s, key: k)
    #expect(stored.snapshot.seriesProviderID == "s1")
    #expect(stored.key == k)
}

@Test func concurrentCompleteAndRemoveDoesNotCorrupt() async throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    let store = f.store
    for i in 0..<20 {
        let k = dkey(provider: "c\(i)")
        try store.insert(snap(), key: k)
        let temp = try tempFile(f, bytes: 16)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? store.completeMoving(from: temp, for: k, expectedMinBytes: 1) }
            group.addTask { try? store.remove(k) }
        }
        // Antingen finns inget kvar, eller så är raden färdig med en fil som finns.
        if let row = try store.download(for: k) {
            #expect(row.state == .completed)
            #expect(FileManager.default.fileExists(atPath: try #require(row.fileURL).path))
        } else {
            #expect(!FileManager.default.fileExists(atPath: temp.path))
        }
    }
    try store.purgeOrphans()
    let rows = try store.list(profileID: dprofile, playlistID: nil)
    for row in rows { #expect(row.state == .completed) }
}

private struct InjectedRemovalFailure: Error {}

@Test func tooSmallFileMarksBadContentEvenIfTempDeletionFails() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    let store = DownloadStore(db: f.db, directory: f.directory, removeItem: { _ in throw InjectedRemovalFailure() })
    try store.insert(snap(), key: dkey())
    let temp = try tempFile(f, bytes: 5)
    #expect(throws: DownloadStoreError.fileTooSmall(actual: 5, required: 100)) {
        try store.completeMoving(from: temp, for: dkey(), expectedMinBytes: 100)
    }
    #expect(try store.download(for: dkey())?.state == .failed(.badContent))
}

@Test func databaseFailureAfterMoveMarksFailedStorageAndKeepsFile() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    try f.store.completeMoving(from: try tempFile(f, bytes: 10), for: dkey(), expectedMinBytes: 1)
    // Ny nedladdning över en tidigare färdig; databasen vägrar sätta completed.
    try f.db.writer.write { db in
        try db.execute(sql: "UPDATE download SET state = 'queued'")
        try db.execute(sql: """
            CREATE TRIGGER refuse_completed BEFORE UPDATE ON download WHEN NEW.state = 'completed'
            BEGIN SELECT RAISE(ABORT, 'refused'); END
            """)
    }
    let temp = try tempFile(f, bytes: 30)
    #expect(throws: (any Error).self) {
        try f.store.completeMoving(from: temp, for: dkey(), expectedMinBytes: 1)
    }
    let row = try #require(try f.store.download(for: dkey()))
    #expect(row.state == .failed(.storage))
    #expect(row.bytesWritten == 0)
    #expect(row.fileURL == nil)
    #expect(try f.store.totalBytes(profileID: dprofile) == 0)
    #expect(filesUnder(f.directory).contains { $0.hasSuffix("media.mkv") })
}

@Test func totalBytesIgnoresRowsFailedByPurge() throws {
    let f = try makeDFixture()
    defer { cleanUp(f) }
    try f.store.insert(snap(), key: dkey())
    let done = try f.store.completeMoving(from: try tempFile(f, bytes: 40), for: dkey(), expectedMinBytes: 1)
    #expect(try f.store.totalBytes(profileID: dprofile) == 40)
    try FileManager.default.removeItem(at: try #require(done.fileURL))
    try f.store.purgeOrphans()
    #expect(try f.store.totalBytes(profileID: dprofile) == 0)
    let relative: String? = try f.db.writer.read { try String.fetchOne($0, sql: "SELECT relativePath FROM download") }
    #expect(relative == nil)
}
