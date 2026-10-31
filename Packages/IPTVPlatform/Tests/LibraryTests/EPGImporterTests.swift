import Core
import Foundation
import GRDB
import Providers
import ProvidersTestSupport
import Testing

@testable import Library

private let pid = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
/// 2023-11-14 22:13:20 UTC.
private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let secretPassword = "hemligtlosen"

private struct XMLHTTP: HTTPClient {
    let body: Data
    var status = 200
    func get(_ url: URL) async throws -> (Data, Int) { (body, status) }
}

private struct LeakyHTTP: HTTPClient {
    func get(_ url: URL) async throws -> (Data, Int) {
        throw URLError(.cannotConnectToHost, userInfo: [
            NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString,
            NSLocalizedDescriptionKey: "Kunde inte ansluta till \(url.absoluteString)",
        ])
    }
}

private func xmltv(extraProgrammes: String = "", truncate: Bool = false) -> Data {
    let body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="svt1.se"><display-name>SVT 1</display-name></channel>
      <channel id="okand.se"><display-name>Okänd kanal</display-name></channel>
      <programme start="20231114220000 +0000" stop="20231114230000 +0000" channel="svt1.se"><title>Rapport</title><desc>Nyheter</desc></programme>
      <programme start="20231114230000 +0000" stop="20231115000000 +0000" channel="svt1.se"><title>Kväll</title></programme>
      <programme start="20231114220000 +0000" stop="20231114230000 +0000" channel="okand.se"><title>Ska inte sparas</title></programme>
      \(extraProgrammes)
    """
    return Data((truncate ? body + "<programme start=\"2023111" : body + "</tv>").utf8)
}

private struct Fixture {
    let importer: EPGImporter
    let store: LibraryStore
    let epg: EPGStore
}

private func fixture(http: HTTPClient, secret: PlaylistSecret? = nil, clock: @escaping @Sendable () -> Date = { now }) throws -> Fixture {
    let db = try AppDatabase.inMemory()
    let store = LibraryStore(db: db)
    let epg = EPGStore(db: db)
    try store.upsertPlaylist(Playlist(id: pid, name: "T", kind: .xtream, createdAt: now))
    let channels = [
        LiveStream(providerID: "1", name: "SVT 1", locator: .xtream(kind: .live, streamID: "1", container: "ts")),
        LiveStream(providerID: "2", name: "Annan kanal", locator: .xtream(kind: .live, streamID: "2", container: "ts")),
    ]
    try store.replaceCatalog(ProviderCatalog(live: channels), playlistID: pid, now: now)
    let creds = InMemoryCredentialStore()
    try creds.save(secret ?? .xtream(server: URL(string: "http://epg.example.invalid")!, username: "anv", password: secretPassword),
                   for: pid)
    return Fixture(importer: EPGImporter(store: store, epg: epg, credentials: creds, http: http, clock: clock),
                   store: store, epg: epg)
}

private func titles(_ f: Fixture, _ channel: String) throws -> [String] {
    let range = now.addingTimeInterval(-10 * 86_400)...now.addingTimeInterval(10 * 86_400)
    return try f.epg.programs(playlistID: pid, channelIDs: [channel], in: range)[channel]?.map(\.title) ?? []
}

@Test func refreshStoresOnlyMatchedChannels() async throws {
    let f = try fixture(http: XMLHTTP(body: xmltv()))
    let count = try await f.importer.refresh(playlistID: pid)
    #expect(count == 2)
    #expect(try titles(f, "svt1.se") == ["Rapport", "Kväll"])
    #expect(try titles(f, "okand.se").isEmpty)
    #expect(try f.epg.lastFetch(playlistID: pid) == now)
    // Kopplingen sparas med importen: varje matchad grupp pekar på sin XMLTV-kanal.
    let map = try f.epg.channelMap(playlistID: pid)
    #expect(!map.isEmpty)
    #expect(Set(map.values).isSubset(of: ["svt1.se"]))
}

@Test func refreshDropsProgramsOutsideWindowAndInvalidOnes() async throws {
    let extra = """
    <programme start="20231101000000 +0000" stop="20231101010000 +0000" channel="svt1.se"><title>Gammalt</title></programme>
    <programme start="20231201000000 +0000" stop="20231201010000 +0000" channel="svt1.se"><title>Långt fram</title></programme>
    <programme start="20231115010000 +0000" stop="20231115000000 +0000" channel="svt1.se"><title>Bakvänt</title></programme>
    """
    let f = try fixture(http: XMLHTTP(body: xmltv(extraProgrammes: extra)))
    #expect(try await f.importer.refresh(playlistID: pid) == 2)
    #expect(try titles(f, "svt1.se") == ["Rapport", "Kväll"])
}

@Test func refreshFailureKeepsOldPrograms() async throws {
    let old = EPGProgram(channelID: "svt1.se", start: now, end: now.addingTimeInterval(600), title: "Gammal")
    let oldFetch = now.addingTimeInterval(-3600)
    for http in [XMLHTTP(body: Data(), status: 500), XMLHTTP(body: xmltv(truncate: true))] {
        let f = try fixture(http: http)
        try f.epg.replacePrograms(playlistID: pid, programs: [old], fetchedAt: oldFetch)
        try f.epg.setChannelMap(playlistID: pid, map: ["gammal-grupp": "svt1.se"])
        await #expect(throws: (any Error).self) { _ = try await f.importer.refresh(playlistID: pid) }
        #expect(try titles(f, "svt1.se") == ["Gammal"])
        #expect(try f.epg.lastFetch(playlistID: pid) == oldFetch)
        #expect(try stagingCount(f) == 0)
        // Ett misslyckat försök rör inte den gamla kopplingen.
        #expect(try f.epg.channelMap(playlistID: pid) == ["gammal-grupp": "svt1.se"])
    }
}

@Test func httpStatusIsMappedToProviderError() async throws {
    let f = try fixture(http: XMLHTTP(body: Data(), status: 403))
    await #expect(throws: ProviderError.unauthorized) { _ = try await f.importer.refresh(playlistID: pid) }
}

@Test func noMatchingProgramsKeepsOldEPG() async throws {
    let empty = Data("<tv><channel id=\"svt1.se\"><display-name>SVT 1</display-name></channel></tv>".utf8)
    let f = try fixture(http: XMLHTTP(body: empty))
    let old = EPGProgram(channelID: "svt1.se", start: now, end: now.addingTimeInterval(600), title: "Gammal")
    try f.epg.replacePrograms(playlistID: pid, programs: [old], fetchedAt: now.addingTimeInterval(-3600))
    try f.epg.setChannelMap(playlistID: pid, map: ["gammal-grupp": "svt1.se"])
    #expect(try await f.importer.refresh(playlistID: pid) == 0)
    #expect(try titles(f, "svt1.se") == ["Gammal"])
    // 0 program: den gamla kopplingen består.
    #expect(try f.epg.channelMap(playlistID: pid) == ["gammal-grupp": "svt1.se"])
}

@Test func needsRefreshAfterTwelveHours() throws {
    let clock = ClockBox(now)
    let f = try fixture(http: XMLHTTP(body: Data()), clock: { clock.value })
    #expect(f.importer.needsRefresh(playlistID: pid))
    try f.epg.replacePrograms(playlistID: pid, programs: [], fetchedAt: now)
    #expect(!f.importer.needsRefresh(playlistID: pid))
    clock.value = now.addingTimeInterval(12 * 3600 - 1)
    #expect(!f.importer.needsRefresh(playlistID: pid))
    clock.value = now.addingTimeInterval(12 * 3600)
    #expect(f.importer.needsRefresh(playlistID: pid))
}

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ d: Date) { current = d }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

@Test func noEpgSourceReturnsZeroWithoutTouchingStore() async throws {
    let f = try fixture(http: LeakyHTTP(), secret: .m3u(url: URL(string: "http://x.example.invalid/p.m3u")!, epgURL: nil))
    #expect(try await f.importer.refresh(playlistID: pid) == 0)
    #expect(try f.epg.lastFetch(playlistID: pid) == nil)
}

@Test func errorDescriptionNeverContainsURL() async throws {
    let f = try fixture(http: LeakyHTTP())
    do {
        _ = try await f.importer.refresh(playlistID: pid)
        Issue.record("förväntade fel")
    } catch {
        for text in [error.localizedDescription, String(describing: error), String(reflecting: error)] {
            #expect(!text.contains(secretPassword))
            #expect(!text.contains("epg.example.invalid"))
            #expect(!text.contains("xmltv"))
        }
        #expect(error as? ProviderError == .unreachable)
    }
}

private func stagingCount(_ f: Fixture) throws -> Int {
    try f.epg.db.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM epgProgramStaging") ?? 0
    }
}

/// Håller en nedladdning tills `open()` anropas.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); c.resume(); return }
            waiting = true
            continuation = c
            lock.unlock()
        }
    }
    func open() {
        lock.lock(); opened = true; let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }
}

private struct GatedHTTP: HTTPClient {
    let gate: Gate
    let body: Data
    func get(_ url: URL) async throws -> (Data, Int) { await gate.wait(); return (body, 200) }
}

private func waitUntilWaiting(_ gate: Gate) async throws {
    for _ in 0..<500 where !gate.isWaiting { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(gate.isWaiting)
}

@Test func concurrentRefreshForSamePlaylistReturnsZeroAndDoesNotDisturbFirst() async throws {
    let gate = Gate()
    let f = try fixture(http: GatedHTTP(gate: gate, body: xmltv()))
    let first = Task { try await f.importer.refresh(playlistID: pid) }
    try await waitUntilWaiting(gate)
    #expect(try await f.importer.refresh(playlistID: pid) == 0)
    #expect(try f.epg.lastFetch(playlistID: pid) == nil)
    gate.open()
    #expect(try await first.value == 2)
    #expect(try titles(f, "svt1.se") == ["Rapport", "Kväll"])
    // Frigjort efter avslut: en ny körning går igenom.
    #expect(try await f.importer.refresh(playlistID: pid) == 2)
}

@Test func cancelledRefreshKeepsOldEPGAndLeavesNoStaging() async throws {
    let gate = Gate()
    let f = try fixture(http: GatedHTTP(gate: gate, body: xmltv()))
    let old = EPGProgram(channelID: "svt1.se", start: now, end: now.addingTimeInterval(600), title: "Gammal")
    try f.epg.replacePrograms(playlistID: pid, programs: [old], fetchedAt: now.addingTimeInterval(-3600))
    let task = Task { try await f.importer.refresh(playlistID: pid) }
    try await waitUntilWaiting(gate)
    task.cancel()
    gate.open()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(try titles(f, "svt1.se") == ["Gammal"])
    #expect(try stagingCount(f) == 0)
    // Frigjort även efter avbrott.
    #expect(try await f.importer.refresh(playlistID: pid) == 2)
}
