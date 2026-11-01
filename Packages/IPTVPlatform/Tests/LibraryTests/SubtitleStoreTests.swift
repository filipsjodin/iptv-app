import Core
import Foundation
import GRDB
import Subtitles
import Testing

@testable import Library

private let spid = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let otherPlaylist = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
private let profile = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
private let otherProfile = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

private func key(profile p: UUID = profile, playlist: UUID = spid, kind: ContentKind = .movie,
                 provider: String = "m1") -> SubtitleKey {
    SubtitleKey(profileID: p, playlistID: playlist, kind: kind, providerID: provider)
}

private func osResult(_ id: Int, language: String = "sv", release: String = "Rel") -> OpenSubtitlesResult {
    OpenSubtitlesResult(id: id, language: language, release: release, fileName: "f\(id).srt", rating: 8,
                        downloadCount: 10, hearingImpaired: false, aiTranslated: false)
}

private let srt = Data("1\n00:00:01,000 --> 00:00:02,000\nHej\n".utf8)

private struct Fixture {
    let store: SubtitleStore
    let db: AppDatabase
    let library: LibraryStore
    let directory: URL
}

private func makeFixture() throws -> Fixture {
    let db = try AppDatabase.inMemory()
    let library = LibraryStore(db: db)
    let created = Date(timeIntervalSince1970: 1000)
    try library.upsertPlaylist(Playlist(id: spid, name: "A", kind: .xtream, createdAt: created))
    try library.upsertPlaylist(Playlist(id: otherPlaylist, name: "B", kind: .m3u, createdAt: created))
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("subtitle-tests-\(UUID().uuidString)", isDirectory: true)
    return Fixture(store: SubtitleStore(db: db, directory: directory), db: db, library: library, directory: directory)
}

private func cleanUp(_ f: Fixture) {
    try? FileManager.default.removeItem(at: f.directory)
}

@Test func saveConvertsCp1252ToUtf8File() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    // "Hej åäö" i Windows-1252 (ogiltig UTF-8).
    let cp1252 = Data([0x31, 0x0A, 0x48, 0x65, 0x6A, 0x20, 0xE5, 0xE4, 0xF6, 0x0A])
    let stored = try f.store.save(cp1252, result: osResult(7), for: key())
    #expect(stored.id == 7 && stored.language == "sv" && stored.release == "Rel")
    let bytes = try Data(contentsOf: stored.fileURL)
    #expect(String(data: bytes, encoding: .utf8) == "1\nHej åäö\n")
    #expect(stored.fileURL.lastPathComponent == "7.srt")
    #expect(stored.fileURL.path.hasPrefix(f.directory.path))
}

@Test func saveRejectsEmptyFile() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    #expect(throws: SubtitleStoreError.emptyFile) {
        try f.store.save(Data("  \n".utf8), result: osResult(1), for: key())
    }
    #expect(try f.store.list(for: key()).isEmpty)
}

@Test func saveReplacesSameFileID() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    _ = try f.store.save(srt, result: osResult(5, language: "sv", release: "Gammal"), for: key())
    let second = try f.store.save(Data("1\n00:00:01,000 --> 00:00:02,000\nNy\n".utf8),
                                  result: osResult(5, language: "sv", release: "Ny"), for: key())
    let listed = try f.store.list(for: key())
    #expect(listed.map(\.id) == [5])
    #expect(listed.first?.release == "Ny")
    #expect(String(decoding: try Data(contentsOf: second.fileURL), as: UTF8.self).contains("Ny"))
}

@Test func listIsPerProfileAndTitle() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    _ = try f.store.save(srt, result: osResult(1), for: key())
    _ = try f.store.save(srt, result: osResult(2, language: "en"), for: key())
    #expect(try f.store.list(for: key()).map(\.id).sorted() == [1, 2])
    #expect(try f.store.list(for: key(profile: otherProfile)).isEmpty)
    #expect(try f.store.list(for: key(provider: "m2")).isEmpty)
    #expect(try f.store.list(for: key(kind: .series)).isEmpty)
    #expect(try f.store.list(for: key(playlist: otherPlaylist)).isEmpty)
}

@Test func providerIDCannotEscapeDirectory() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    let stored = try f.store.save(srt, result: osResult(1), for: key(provider: "../../etc/x"))
    #expect(stored.fileURL.standardizedFileURL.path.hasPrefix(f.directory.standardizedFileURL.path + "/"))
    #expect(FileManager.default.fileExists(atPath: stored.fileURL.path))
}

@Test func removeDeletesRowAndFile() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    let a = try f.store.save(srt, result: osResult(1), for: key())
    let b = try f.store.save(srt, result: osResult(2), for: key())
    try f.store.remove(fileID: 1, for: key())
    #expect(try f.store.list(for: key()).map(\.id) == [2])
    #expect(!FileManager.default.fileExists(atPath: a.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: b.fileURL.path))
    try f.store.remove(fileID: 1, for: key())  // idempotent
}

@Test func offsetRoundTripsAndClamps() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    #expect(try f.store.offset(for: key()) == 0)
    try f.store.setOffset(2.34, for: key())
    #expect(try f.store.offset(for: key()) == 2.3)
    try f.store.setOffset(-1.5, for: key())
    #expect(try f.store.offset(for: key()) == -1.5)
    try f.store.setOffset(9999, for: key())
    #expect(try f.store.offset(for: key()) == 600)
    try f.store.setOffset(-9999, for: key())
    #expect(try f.store.offset(for: key()) == -600)
    try f.store.setOffset(.nan, for: key())
    #expect(try f.store.offset(for: key()) == 0)
    #expect(try f.store.offset(for: key(profile: otherProfile)) == 0)
}

@Test func techInfoRoundTrips() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    #expect(try f.store.techInfo(for: key()) == nil)
    let info = TitleTechInfo(audioLanguages: ["sv", "en"], subtitleLanguages: ["sv"], videoSummary: "1080p HEVC",
                             engine: "AVPlayer", recordedAt: Date(timeIntervalSince1970: 1_000_000))
    try f.store.recordTechInfo(info, for: key())
    #expect(try f.store.techInfo(for: key()) == info)
    #expect(try f.store.techInfo(for: key(profile: otherProfile)) == nil)
    let newer = TitleTechInfo(audioLanguages: ["en"], subtitleLanguages: [], recordedAt: Date(timeIntervalSince1970: 2))
    try f.store.recordTechInfo(newer, for: key())
    #expect(try f.store.techInfo(for: key()) == newer)
}

@Test func removingPlaylistCascades() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    let gone = try f.store.save(srt, result: osResult(1), for: key())
    let kept = try f.store.save(srt, result: osResult(2), for: key(playlist: otherPlaylist))
    try f.store.setOffset(1, for: key())
    try f.store.recordTechInfo(
        TitleTechInfo(audioLanguages: [], subtitleLanguages: [], recordedAt: Date(timeIntervalSince1970: 1)),
        for: key())

    try f.library.deletePlaylist(spid)

    let counts = try f.db.writer.read { db in
        try ["subtitleFile", "subtitleOffset", "titleTechInfo"].map {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE playlistID = ?", arguments: [spid.uuidString]) ?? -1
        }
    }
    #expect(counts == [0, 0, 0])
    #expect(try f.store.list(for: key(playlist: otherPlaylist)).map(\.id) == [2])
    // Filen finns kvar tills den städas.
    #expect(FileManager.default.fileExists(atPath: gone.fileURL.path))
    #expect(try f.store.purgeOrphans() == 1)
    #expect(!FileManager.default.fileExists(atPath: gone.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: kept.fileURL.path))
    #expect(try f.store.purgeOrphans() == 0)
}

@Test func purgeOrphansWithoutDirectoryIsNoOp() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    #expect(try f.store.purgeOrphans() == 0)
}

// MARK: - Synk av förskjutningar (v10)

private func offsetRow(_ f: Fixture, _ k: SubtitleKey) throws -> (ms: Int, updatedAt: Double)? {
    try f.db.writer.read { db in
        try Row.fetchOne(db, sql: """
            SELECT offsetMs, updatedAt FROM subtitleOffset
            WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ?
            """, arguments: [k.profileID.uuidString, k.playlistID.uuidString, k.kind.rawValue, k.providerID])
            .map { (ms: $0["offsetMs"] as Int, updatedAt: $0["updatedAt"] as Double) }
    }
}

@Test func setOffsetStoresUpdatedAt() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    try f.store.setOffset(1.5, for: key(), now: Date(timeIntervalSince1970: 5000))
    let row = try #require(try offsetRow(f, key()))
    #expect(row.ms == 1500 && row.updatedAt == 5000)
}

@Test func localNewerOffsetNotOverwritten() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    try f.store.setOffset(2, for: key(), now: Date(timeIntervalSince1970: 5000))
    let applied = try f.store.applyRemoteOffset(-7000, key: key(), updatedAt: Date(timeIntervalSince1970: 4000))
    #expect(applied == false)
    let row = try #require(try offsetRow(f, key()))
    #expect(row.ms == 2000 && row.updatedAt == 5000)
}

@Test func equalTimestampRemoteOffsetIgnored() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    try f.store.setOffset(2, for: key(), now: Date(timeIntervalSince1970: 5000))
    #expect(try f.store.applyRemoteOffset(9000, key: key(), updatedAt: Date(timeIntervalSince1970: 5000)) == false)
    #expect(try offsetRow(f, key())?.ms == 2000)
}

@Test func remoteOffsetStoredWithoutFiles() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    let stored = try f.store.save(srt, result: osResult(3), for: key())
    #expect(try offsetRow(f, key()) == nil)

    let applied = try f.store.applyRemoteOffset(-2500, key: key(), updatedAt: Date(timeIntervalSince1970: 7000))
    #expect(applied)
    let row = try #require(try offsetRow(f, key()))
    #expect(row.ms == -2500 && row.updatedAt == 7000)  // fjärrens tid, ingen bump till nu
    #expect(try f.store.offset(for: key()) == -2.5)

    // Filer och addedAt är orörda.
    let list = try f.store.list(for: key())
    #expect(list.map(\.id) == [3])
    #expect(list.first?.addedAt == stored.addedAt)
    #expect(FileManager.default.fileExists(atPath: stored.fileURL.path))

    // En nyare fjärrvärde skriver över, en äldre gör det inte.
    #expect(try f.store.applyRemoteOffset(100, key: key(), updatedAt: Date(timeIntervalSince1970: 8000)))
    #expect(try offsetRow(f, key())?.ms == 100)
}

@Test func remoteOffsetForUnknownPlaylistIsSkipped() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    let unknown = key(playlist: UUID())
    #expect(try f.store.applyRemoteOffset(100, key: unknown, updatedAt: Date(timeIntervalSince1970: 8000)) == false)
    #expect(try offsetRow(f, unknown) == nil)
}

@Test func offsetsListsOnlyThatProfile() throws {
    let f = try makeFixture()
    defer { cleanUp(f) }
    try f.store.setOffset(1, for: key(), now: Date(timeIntervalSince1970: 100))
    try f.store.setOffset(-2, for: key(kind: .series, provider: "e1"), now: Date(timeIntervalSince1970: 200))
    try f.store.setOffset(3, for: key(profile: otherProfile), now: Date(timeIntervalSince1970: 300))

    let mine = try f.store.offsets(profileID: profile)
    #expect(mine.count == 2)
    #expect(Set(mine.map { $0.key }) == [key(), key(kind: .series, provider: "e1")])
    let movie = try #require(mine.first { $0.key == key() })
    #expect(movie.offsetMs == 1000 && movie.updatedAt == Date(timeIntervalSince1970: 100))
    let other = try f.store.offsets(profileID: otherProfile)
    #expect(other.map { $0.offsetMs } == [3000])
    #expect(try f.store.offsets(profileID: UUID()).isEmpty)
}
