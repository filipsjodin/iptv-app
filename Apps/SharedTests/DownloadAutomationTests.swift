#if !os(tvOS)
import Core
import Downloads
import Foundation
import GRDB
import Library
import PlaybackCore
import Providers
import ProvidersTestSupport
import Subtitles
import Testing
@testable import IPTVApp

// MARK: - Fakes

private final class AutoTransport: DownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var startedHandles: [DownloadTaskHandle] = []
    let events: AsyncStream<DownloadTransportEvent>
    private let continuation: AsyncStream<DownloadTransportEvent>.Continuation

    init() {
        let pair = AsyncStream<DownloadTransportEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    var handles: [DownloadTaskHandle] { lock.withLock { startedHandles } }

    func emit(_ event: DownloadTransportEvent) { continuation.yield(event) }

    func start(_ request: DownloadTransportRequest) async throws -> DownloadTaskHandle {
        lock.withLock {
            let handle = DownloadTaskHandle(key: request.key, taskID: startedHandles.count + 1)
            startedHandles.append(handle)
            return handle
        }
    }

    func pause(_ handle: DownloadTaskHandle) async -> Data? { nil }
    func cancel(_ handle: DownloadTaskHandle) async {}
    func reattach() async -> [DownloadTaskHandle] { [] }
}

private final class SwitchableNetwork: NetworkPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private var wifi: Bool
    private var continuations: [AsyncStream<NetworkStatus>.Continuation] = []
    init(wifi: Bool) { self.wifi = wifi }
    var status: NetworkStatus { lock.withLock { NetworkStatus(isOnline: true, isOnWifi: wifi) } }
    var changes: AsyncStream<NetworkStatus> {
        AsyncStream { continuation in
            lock.withLock { continuations.append(continuation) }
            continuation.yield(status)
        }
    }

    func set(wifi value: Bool) {
        let targets = lock.withLock { () -> [AsyncStream<NetworkStatus>.Continuation] in
            wifi = value
            return continuations
        }
        for target in targets { target.yield(NetworkStatus(isOnline: true, isOnWifi: value)) }
    }
}

// MARK: - Uppsättning

@MainActor
private struct AutomationHarness {
    let model: AppModel
    let playlistID: UUID
    let store: DownloadStore
    let transport: AutoTransport
    let subtitles: SubtitleStore
    let userState: InMemoryUserStateStore
    let network: SwitchableNetwork
    let root: URL

    var manager: DownloadManager { model.downloadManager! }

    func key(_ id: String = "101", kind: ContentKind = .movie) -> DownloadKey {
        DownloadKey(profileID: model.activeProfile!.profile.id, playlistID: playlistID, kind: kind, providerID: id)
    }

    func state(_ key: DownloadKey) -> DownloadState? { manager.items.first { $0.key == key }?.state }

    /// Köar och slutför en nedladdning via transporten.
    func complete(_ key: DownloadKey) async throws {
        if key.kind == .movie {
            try await model.downloadMovie(providerID: key.providerID, playlistID: playlistID)
        } else {
            try await model.downloadEpisode(providerID: key.providerID, seriesProviderID: "5", playlistID: playlistID)
        }
        let handle = try #require(transport.handles.last { $0.key == key })
        let dir = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(UUID().uuidString)
        // Över DownloadResponseCheck.minimumPlausibleBytes (64 KiB): API-raden saknar expectedBytes.
        try Data(repeating: 9, count: 70_000).write(to: file)
        transport.emit(.finished(handle, stagedFile: file, status: 200, contentType: "video/mp4"))
        #expect(await wait { state(key) == .completed })
    }

    func watch(_ key: DownloadKey, fraction: Double = 0.95) {
        let progressKey = ProgressKey(playlistID: key.playlistID, kind: key.kind, providerID: key.providerID,
                                      seriesProviderID: key.kind == .series ? "5" : nil)
        let progress = ProgressPolicy.progress(key: progressKey, position: fraction * 1000, duration: 1000,
                                               now: Date())!
        model.watchObservingUserState().save(progress)
    }
}

@MainActor
private func wait(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func makeHarness(autoDelete: Bool = false, autoNext: Bool = false, wifi: Bool = true,
                         beforeStart: (URL) throws -> Void = { _ in }) async throws -> AutomationHarness {
    let db = try AppDatabase.inMemory()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("download-automation-tests-\(UUID().uuidString)", isDirectory: true)
    let subtitles = SubtitleStore(db: db, directory: root.appendingPathComponent("subtitles", isDirectory: true))
    let userState = InMemoryUserStateStore()
    let model = AppModel(store: LibraryStore(db: db), credentials: InMemoryCredentialStore(),
                         http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults(),
                         userState: userState, subtitleStore: subtitles)
    await model.addPlaylist(name: "Min", secret: xtreamSecret)
    let playlistID = try #require(model.playlists.first?.id)
    let storeDirectory = root.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    try beforeStart(storeDirectory)
    let store = DownloadStore(db: db, directory: storeDirectory)
    let transport = AutoTransport()
    let network = SwitchableNetwork(wifi: wifi)
    model.attachDownloads(store: store, transport: transport, network: network,
                          freeSpace: { 100_000_000_000 })
    await model.downloadManager?.start()
    model.enter(playlistID: playlistID)
    model.settings.downloads = DownloadSettings(wifiOnly: false, autoDeleteWatched: autoDelete,
                                                autoNextEpisode: autoNext)
    return AutomationHarness(model: model, playlistID: playlistID, store: store, transport: transport, subtitles: subtitles,
                   userState: userState, network: network, root: root)
}

// MARK: - Tester

@MainActor
struct DownloadAutomationTests {
    @Test func watchedAutoDeleteRemovesFileNotSubtitles() async throws {
        let h = try await makeHarness(autoDelete: true)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let key = h.key()
        try await h.complete(key)
        let file = try #require(h.manager.items.first { $0.key == key }?.fileURL)
        let subtitleKey = SubtitleKey(profileID: key.profileID, playlistID: key.playlistID, kind: key.kind,
                                      providerID: key.providerID)
        let result = OpenSubtitlesResult(id: 11, language: "sv", release: "Rel", fileName: "a.srt", rating: 1,
                                         downloadCount: 1, hearingImpaired: false, aiTranslated: false)
        _ = try h.subtitles.save(Data("1\n00:00:01,000 --> 00:00:02,000\nHej\n".utf8), result: result,
                                 for: subtitleKey)

        h.watch(key)
        #expect(await wait { h.state(key) == nil })
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try h.store.download(for: key) == nil)
        #expect(try h.subtitles.list(for: subtitleKey).count == 1)
    }

    @Test func autoDeleteOffKeepsDownload() async throws {
        let h = try await makeHarness(autoDelete: false)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let key = h.key()
        try await h.complete(key)
        h.watch(key)
        try await Task.sleep(for: .milliseconds(200))
        await h.model.watchedProcessingTask?.value
        #expect(h.state(key) == .completed)
    }

    @Test func playingItemIsNeverAutoDeleted() async throws {
        let h = try await makeHarness(autoDelete: true)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let key = h.key()
        try await h.complete(key)
        let file = try #require(h.manager.items.first { $0.key == key }?.fileURL)

        h.model.playerDidOpen()
        h.watch(key)
        #expect(await wait { !h.model.pendingWatchedDownloads.isEmpty })
        await h.model.processWatchedDownloads()
        #expect(h.state(key) == .completed)
        #expect(FileManager.default.fileExists(atPath: file.path))

        // Först när spelaren stängts raderas den.
        h.model.playerDidClose()
        #expect(await wait { h.state(key) == nil })
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func profileRemovalPurgesItsDownloads() async throws {
        let h = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let key = h.key()
        try await h.complete(key)
        let file = try #require(h.manager.items.first { $0.key == key }?.fileURL)
        let doomed = h.model.activeProfile!.profile
        _ = try h.model.addProfile(playlistID: h.playlistID, name: "Andra", avatar: "star.fill")

        try h.model.deleteProfile(doomed)
        await h.model.downloadCleanupTask?.value
        #expect(h.manager.items.isEmpty)
        #expect(try h.store.download(for: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func startupPurgeRunsOffMain() async throws {
        var orphan: URL?
        let h = try await makeHarness { directory in
            let dir = directory.appendingPathComponent("p/pl/movie/x", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("video.mp4"))
            orphan = dir
        }
        defer { try? FileManager.default.removeItem(at: h.root) }
        // Föräldralösa kataloger rensas av hanterarens start (`purgeOrphans` utanför huvudaktören).
        #expect(!FileManager.default.fileExists(atPath: try #require(orphan).path))
    }

    @Test func autoNextQueuesNextEpisodeOnWifi() async throws {
        let h = try await makeHarness(autoNext: true)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let first = h.key("501", kind: .series)
        try await h.complete(first)
        h.watch(first)
        #expect(await wait { h.state(h.key("502", kind: .series)) != nil })
        #expect(h.manager.items.filter { $0.key.kind == .series }.count == 2)
    }

    @Test func autoNextNeverOnCellular() async throws {
        let h = try await makeHarness(autoNext: true, wifi: false)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let first = h.key("501", kind: .series)
        try await h.complete(first)
        h.watch(first)
        try await Task.sleep(for: .milliseconds(200))
        await h.model.watchedProcessingTask?.value
        #expect(h.manager.items.filter { $0.key.kind == .series }.count == 1)
    }

    @Test func bingeKeepsAllPendingEntriesWhenPlayerReopens() async throws {
        let h = try await makeHarness(autoDelete: true)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let first = h.key("101"), second = h.key("102")
        try await h.complete(first)
        try await h.complete(second)

        h.model.playerDidOpen()
        h.watch(first)
        h.watch(second)
        #expect(await wait { h.model.pendingWatchedDownloads.count == 2 })
        // Spelaren är öppen igen: ingenting bearbetas och ingenting tappas.
        await h.model.processWatchedDownloads()
        #expect(h.model.pendingWatchedDownloads.count == 2)
        #expect(h.state(first) == .completed)
        #expect(h.state(second) == .completed)

        h.model.playerDidClose()
        #expect(await wait { h.state(first) == nil && h.state(second) == nil })
        #expect(h.model.pendingWatchedDownloads.isEmpty)
    }

    @Test func autoQueuedRowPausesOnCellularEvenWhenNotWifiOnly() async throws {
        let h = try await makeHarness(autoNext: true)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let first = h.key("501", kind: .series), next = h.key("502", kind: .series)
        try await h.complete(first)
        h.watch(first)
        #expect(await wait { h.state(next) != nil })
        h.network.set(wifi: false)
        #expect(await wait { h.state(next) == .paused(.waitingForWifi) })
        h.network.set(wifi: true)
        #expect(await wait { h.state(next) != .paused(.waitingForWifi) })
    }

    @Test func concurrentChecksQueueAtMostOneEpisode() async throws {
        let h = try await makeHarness(autoNext: true)
        defer { try? FileManager.default.removeItem(at: h.root) }
        try await h.complete(h.key("501", kind: .series))
        let before = h.manager.items.count
        async let a: Void = h.model.checkAutoNextEpisodes()
        async let b: Void = h.model.checkAutoNextEpisodes()
        async let c: Void = h.model.checkAutoNextEpisodes()
        _ = await (a, b, c)
        #expect(h.manager.items.count <= before + 1)
    }

    @Test func requiresWifiSurvivesRestartAndBlocksCellular() async throws {
        let h = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let flagged = h.key("101"), plain = h.key("102")
        func snapshot(_ id: String) -> DownloadSnapshot {
            DownloadSnapshot(title: id, locator: .xtream(kind: .movie, streamID: id, container: "mkv"))
        }
        try h.store.insert(snapshot("101"), key: flagged, requiresWifi: true)
        try h.store.insert(snapshot("102"), key: plain)
        #expect(try h.store.download(for: flagged)?.requiresWifi == true)
        #expect(try h.store.download(for: plain)?.requiresWifi == false)

        // Ny hanterare = omstart, på mobil och med "bara wifi" av.
        let transport = AutoTransport()
        let model = h.model
        let manager = DownloadManager(
            store: h.store, transport: transport, broker: model.broker,
            network: SwitchableNetwork(wifi: false), freeSpace: { 100_000_000_000 },
            secret: { id in try await model.playbackSecret(for: id) })
        defer { manager.stop() }
        await manager.configure(DownloadSettings(wifiOnly: false))
        await manager.start()
        #expect(await wait { transport.handles.contains { $0.key == plain } })
        #expect(!transport.handles.contains { $0.key == flagged })
        #expect(manager.items.first { $0.key == flagged }?.state == .queued)
    }

    @Test func autoNextNeedsADownloadedEpisodeOfTheSeries() async throws {
        let h = try await makeHarness(autoNext: true)
        defer { try? FileManager.default.removeItem(at: h.root) }
        // 501 sågs online och är inte nedladdad: inget nästa avsnitt köas.
        h.watch(h.key("501", kind: .series))
        try await Task.sleep(for: .milliseconds(200))
        await h.model.watchedProcessingTask?.value
        #expect(h.manager.items.isEmpty)
    }

    @Test func startupRemovesDownloadsOfRemovedProfiles() async throws {
        let h = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let mine = h.key()
        let ghost = DownloadKey(profileID: UUID(), playlistID: h.playlistID, kind: .movie, providerID: "102")
        try await h.manager.enqueue(
            DownloadSnapshot(title: "Spöke", locator: .xtream(kind: .movie, streamID: "102", container: "mkv")),
            key: ghost)
        try await h.model.downloadMovie(providerID: "101", playlistID: h.playlistID)
        #expect(h.state(ghost) != nil)

        await h.model.purgeDownloadsOfRemovedProfiles()
        #expect(h.state(ghost) == nil)
        #expect(try h.store.download(for: ghost) == nil)
        #expect(h.state(mine) != nil)
    }

    @Test func autoNextRespectsKids() async throws {
        let h = try await makeHarness(autoDelete: true, autoNext: true)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let first = h.key("501", kind: .series)
        try await h.complete(first)
        let kid = try h.model.addProfile(playlistID: h.playlistID, name: "Barn", avatar: "pawprint.fill",
                                         isKids: true)
        try await h.model.select(profile: kid, pin: nil)
        h.model.settings.downloads = DownloadSettings(wifiOnly: false, autoDeleteWatched: true,
                                                      autoNextEpisode: true)
        // Barnprofilen får standardvärden, vad som än sparats.
        #expect(h.model.currentDownloadSettings == DownloadSettings())

        h.model.noteBecameWatched(
            WatchProgress(key: ProgressKey(playlistID: h.playlistID, kind: .series, providerID: "501",
                                           seriesProviderID: "5"),
                          position: 990, duration: 1000, watched: true, updatedAt: Date()),
            profileID: kid.id)
        #expect(h.model.pendingWatchedDownloads.isEmpty)
        #expect(h.manager.items.filter { $0.key.kind == .series }.count == 1)
    }
}
#endif
