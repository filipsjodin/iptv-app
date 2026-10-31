import Core
import Foundation
import GRDB
import Testing

@testable import Library

private let epgPID = UUID(uuidString: "00000000-0000-0000-0000-0000000000EE")!
private let epgOtherPID = UUID(uuidString: "00000000-0000-0000-0000-0000000000EF")!
private let base = Date(timeIntervalSince1970: 1_000_000)

private func at(_ minutes: Double) -> Date { base + minutes * 60 }

private func prog(_ channel: String, _ from: Double, _ to: Double, _ title: String = "P") -> EPGProgram {
    EPGProgram(channelID: channel, start: at(from), end: at(to), title: title, summary: "Om \(title)")
}

private func fixture() throws -> (store: EPGStore, db: AppDatabase, library: LibraryStore) {
    let db = try AppDatabase.inMemory()
    let library = LibraryStore(db: db)
    try library.upsertPlaylist(Playlist(id: epgPID, name: "Test", kind: .xtream, createdAt: base))
    try library.upsertPlaylist(Playlist(id: epgOtherPID, name: "Annan", kind: .m3u, createdAt: base))
    return (EPGStore(db: db), db, library)
}

/// Ett ogiltigt program (slut före start) bryter tabellens CHECK mitt i batchen och rullar tillbaka transaktionen.
@Test func replaceIsAtomicWhenSequenceThrowsMidway() throws {
    let f = try fixture()
    try f.store.replacePrograms(playlistID: epgPID, programs: [prog("a", 0, 30, "Gammal")], fetchedAt: at(1))

    let batch = [prog("a", 100, 130, "Ny 1"), prog("a", 130, 160, "Ny 2"), prog("a", 200, 190, "Ogiltig"),
                 prog("a", 200, 230, "Ny 4")]
    #expect(throws: (any Error).self) {
        try f.store.replacePrograms(playlistID: epgPID, programs: batch, fetchedAt: at(2))
    }

    let kept = try f.store.programs(playlistID: epgPID, channelIDs: ["a"], in: at(-1000)...at(1000))
    #expect(kept["a"]?.map(\.title) == ["Gammal"])
    #expect(try f.store.lastFetch(playlistID: epgPID) == at(1))
}

@Test func replaceReplacesPreviousProgramsAndFetchTime() throws {
    let f = try fixture()
    try f.store.replacePrograms(playlistID: epgPID, programs: [prog("a", 0, 30, "Gammal")], fetchedAt: at(1))
    try f.store.replacePrograms(playlistID: epgPID, programs: [prog("a", 40, 70, "Ny")], fetchedAt: at(2))
    let all = try f.store.programs(playlistID: epgPID, channelIDs: ["a"], in: at(-1000)...at(1000))
    #expect(all["a"]?.map(\.title) == ["Ny"])
    #expect(all["a"]?.first?.summary == "Om Ny")
    #expect(try f.store.lastFetch(playlistID: epgPID) == at(2))
    #expect(try f.store.lastFetch(playlistID: epgOtherPID) == nil)
}

@Test func nowNextPicksCurrentAndFollowing() throws {
    let f = try fixture()
    try f.store.replacePrograms(playlistID: epgPID, programs: [
        prog("a", 0, 30, "Ett"), prog("a", 30, 60, "Två"), prog("a", 60, 90, "Tre"),
        prog("b", 100, 130, "Framtid"),
    ], fetchedAt: at(1))
    let result = try f.store.nowNext(playlistID: epgPID, channelIDs: ["a", "b", "c"], at: at(45))
    #expect(result["a"]?.now?.title == "Två")
    #expect(result["a"]?.next?.title == "Tre")
    // Utan pågående program är nästa det första som börjar senare.
    #expect(result["b"]?.now == nil)
    #expect(result["b"]?.next?.title == "Framtid")
    #expect(result["c"] == nil)
    // Slutet är exklusivt: vid 60 har "Två" slutat.
    let boundary = try f.store.nowNext(playlistID: epgPID, channelIDs: ["a"], at: at(60))
    #expect(boundary["a"]?.now?.title == "Tre")
    #expect(boundary["a"]?.next == nil)
}

@Test func programsInRangeIncludesOverlappingAtEdges() throws {
    let f = try fixture()
    try f.store.replacePrograms(playlistID: epgPID, programs: [
        prog("a", 0, 30, "Före"), prog("a", 30, 60, "Över början"), prog("a", 60, 90, "Inuti"),
        prog("a", 90, 120, "Över slutet"), prog("a", 120, 150, "Efter"),
    ], fetchedAt: at(1))
    // Intervallet 45...100: "Före" slutar före 45; "Efter" börjar efter 100.
    let result = try f.store.programs(playlistID: epgPID, channelIDs: ["a"], in: at(45)...at(100))
    #expect(result["a"]?.map(\.title) == ["Över början", "Inuti", "Över slutet"])
    // Ett program som slutar exakt vid intervallets början ingår inte.
    let touching = try f.store.programs(playlistID: epgPID, channelIDs: ["a"], in: at(60)...at(60))
    #expect(touching["a"]?.map(\.title) == ["Inuti"])
}

@Test func programsForUnknownChannelAreEmpty() throws {
    let f = try fixture()
    try f.store.replacePrograms(playlistID: epgPID, programs: [prog("a", 0, 30)], fetchedAt: at(1))
    let result = try f.store.programs(playlistID: epgPID, channelIDs: ["saknas"], in: at(0)...at(100))
    #expect(result["saknas"]?.isEmpty ?? true)
    let other = try f.store.programs(playlistID: epgOtherPID, channelIDs: ["a"], in: at(0)...at(100))
    #expect(other["a"]?.isEmpty ?? true)
}

@Test func pruneRemovesOnlyOldPrograms() throws {
    let f = try fixture()
    try f.store.replacePrograms(playlistID: epgPID, programs: [
        prog("a", 0, 30, "Gammal"), prog("a", 50, 80, "Pågår"), prog("a", 90, 120, "Kommande"),
    ], fetchedAt: at(1))
    try f.store.prune(before: at(60))
    let result = try f.store.programs(playlistID: epgPID, channelIDs: ["a"], in: at(-1000)...at(1000))
    #expect(result["a"]?.map(\.title) == ["Pågår", "Kommande"])
}

@Test func removingPlaylistRemovesEpgAndSplits() throws {
    let f = try fixture()
    try f.store.replacePrograms(playlistID: epgPID, programs: [prog("a", 0, 30)], fetchedAt: at(1))
    try f.store.replacePrograms(playlistID: epgOtherPID, programs: [prog("a", 0, 30)], fetchedAt: at(1))
    try f.store.setSplit(playlistID: epgPID, providerID: "s1", split: true)
    try f.store.setSplit(playlistID: epgOtherPID, providerID: "s1", split: true)

    try f.library.deletePlaylist(epgPID)

    let counts = try f.db.writer.read { db in
        try ["epgProgram", "epgMeta", "channelSplit"].map {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE playlistID = ?",
                             arguments: [epgPID.uuidString]) ?? -1
        }
    }
    #expect(counts == [0, 0, 0])
    #expect(try f.store.lastFetch(playlistID: epgPID) == nil)
    // Den andra spellistan är orörd.
    #expect(try f.store.lastFetch(playlistID: epgOtherPID) == at(1))
    #expect(try f.store.splitProviderIDs(playlistID: epgOtherPID) == ["s1"])
}

@Test func splitRoundTrips() throws {
    let f = try fixture()
    #expect(try f.store.splitProviderIDs(playlistID: epgPID).isEmpty)
    try f.store.setSplit(playlistID: epgPID, providerID: "s1", split: true)
    try f.store.setSplit(playlistID: epgPID, providerID: "s1", split: true)   // idempotent
    try f.store.setSplit(playlistID: epgPID, providerID: "s2", split: true)
    #expect(try f.store.splitProviderIDs(playlistID: epgPID) == ["s1", "s2"])
    try f.store.setSplit(playlistID: epgPID, providerID: "s1", split: false)
    #expect(try f.store.splitProviderIDs(playlistID: epgPID) == ["s2"])
    #expect(try f.store.splitProviderIDs(playlistID: epgOtherPID).isEmpty)
}

private func stagingCount(_ f: (store: EPGStore, db: AppDatabase, library: LibraryStore), _ pid: UUID) throws -> Int {
    try f.db.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM epgProgramStaging WHERE playlistID = ?",
                         arguments: [pid.uuidString]) ?? -1
    }
}

@Test func stagedRowsInvisibleUntilCommit() throws {
    let f = try fixture()
    try f.store.replacePrograms(playlistID: epgPID, programs: [prog("a", 0, 60, "Gammal")], fetchedAt: at(1))
    try f.store.beginStaging(playlistID: epgPID)
    try f.store.stage(playlistID: epgPID, programs: [prog("a", 0, 60, "Ny")])
    try f.store.stage(playlistID: epgPID, programs: [prog("a", 60, 90, "Ny 2")])

    #expect(try stagingCount(f, epgPID) == 2)
    let before = try f.store.programs(playlistID: epgPID, channelIDs: ["a"], in: at(-1000)...at(1000))
    #expect(before["a"]?.map(\.title) == ["Gammal"])
    #expect(try f.store.nowNext(playlistID: epgPID, channelIDs: ["a"], at: at(30))["a"]?.now?.title == "Gammal")
    #expect(try f.store.lastFetch(playlistID: epgPID) == at(1))
}

@Test func commitReplacesOldProgramsAtomically() throws {
    let f = try fixture()
    try f.store.replacePrograms(playlistID: epgPID, programs: [prog("a", 0, 60, "Gammal")], fetchedAt: at(1))
    try f.store.replacePrograms(playlistID: epgOtherPID, programs: [prog("a", 0, 60, "Annan")], fetchedAt: at(1))
    try f.store.beginStaging(playlistID: epgPID)
    try f.store.stage(playlistID: epgPID, programs: [prog("a", 100, 160, "Ny"), prog("b", 0, 30, "B")])
    try f.store.commitStaging(playlistID: epgPID, fetchedAt: at(5))

    let all = try f.store.programs(playlistID: epgPID, channelIDs: ["a", "b"], in: at(-1000)...at(1000))
    #expect(all["a"]?.map(\.title) == ["Ny"])
    #expect(all["b"]?.map(\.title) == ["B"])
    #expect(try f.store.lastFetch(playlistID: epgPID) == at(5))
    #expect(try stagingCount(f, epgPID) == 0)
    // Den andra spellistan är orörd.
    let other = try f.store.programs(playlistID: epgOtherPID, channelIDs: ["a"], in: at(-1000)...at(1000))
    #expect(other["a"]?.map(\.title) == ["Annan"])
}

@Test func discardLeavesOldProgramsAndFetchTimeUntouched() throws {
    let f = try fixture()
    try f.store.replacePrograms(playlistID: epgPID, programs: [prog("a", 0, 60, "Gammal")], fetchedAt: at(1))
    try f.store.beginStaging(playlistID: epgPID)
    try f.store.stage(playlistID: epgPID, programs: [prog("a", 100, 160, "Ny")])
    try f.store.discardStaging(playlistID: epgPID)

    #expect(try stagingCount(f, epgPID) == 0)
    let kept = try f.store.programs(playlistID: epgPID, channelIDs: ["a"], in: at(-1000)...at(1000))
    #expect(kept["a"]?.map(\.title) == ["Gammal"])
    #expect(try f.store.lastFetch(playlistID: epgPID) == at(1))
}

@Test func beginStagingClearsLeftovers() throws {
    let f = try fixture()
    try f.store.beginStaging(playlistID: epgPID)
    try f.store.stage(playlistID: epgPID, programs: [prog("a", 0, 30, "Kvar")])
    try f.store.stage(playlistID: epgOtherPID, programs: [prog("a", 0, 30, "Annan")])
    try f.store.beginStaging(playlistID: epgPID)
    try f.store.stage(playlistID: epgPID, programs: [prog("a", 40, 70, "Färsk")])
    try f.store.commitStaging(playlistID: epgPID, fetchedAt: at(2))

    let all = try f.store.programs(playlistID: epgPID, channelIDs: ["a"], in: at(-1000)...at(1000))
    #expect(all["a"]?.map(\.title) == ["Färsk"])
    // Den andra spellistans mellanlagring rensades inte.
    #expect(try stagingCount(f, epgOtherPID) == 1)
}

@Test func removingPlaylistRemovesStagingRows() throws {
    let f = try fixture()
    try f.store.stage(playlistID: epgPID, programs: [prog("a", 0, 30)])
    try f.store.stage(playlistID: epgOtherPID, programs: [prog("a", 0, 30)])
    try f.library.deletePlaylist(epgPID)
    #expect(try stagingCount(f, epgPID) == 0)
    #expect(try stagingCount(f, epgOtherPID) == 1)
}
