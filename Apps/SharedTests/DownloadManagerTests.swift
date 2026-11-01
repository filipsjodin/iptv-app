#if !os(tvOS)
import Core
import Downloads
import Foundation
import Library
import PlaybackCore
import Testing
@testable import IPTVApp

// MARK: - Fakes

/// Transport som registrerar anropen och låter testet skicka händelser.
private final class FakeTransport: DownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var startedRequests: [DownloadTransportRequest] = []
    private var startedHandles: [DownloadTaskHandle] = []
    private var pausedHandles: [DownloadTaskHandle] = []
    private var cancelledHandles: [DownloadTaskHandle] = []
    private var runningHandles: [DownloadTaskHandle] = []
    private var nextID = 1
    let events: AsyncStream<DownloadTransportEvent>
    private let continuation: AsyncStream<DownloadTransportEvent>.Continuation

    init() {
        let pair = AsyncStream<DownloadTransportEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    var started: [DownloadTransportRequest] { lock.withLock { startedRequests } }
    var handles: [DownloadTaskHandle] { lock.withLock { startedHandles } }
    var paused: [DownloadTaskHandle] { lock.withLock { pausedHandles } }
    var cancelled: [DownloadTaskHandle] { lock.withLock { cancelledHandles } }

    func addRunning(_ handle: DownloadTaskHandle) {
        lock.withLock { runningHandles.append(handle) }
    }

    func emit(_ event: DownloadTransportEvent) {
        continuation.yield(event)
    }

    func start(_ request: DownloadTransportRequest) async throws -> DownloadTaskHandle {
        lock.withLock {
            let handle = DownloadTaskHandle(key: request.key, taskID: nextID)
            nextID += 1
            startedRequests.append(request)
            startedHandles.append(handle)
            runningHandles.append(handle)
            return handle
        }
    }

    func pause(_ handle: DownloadTaskHandle) async -> Data? {
        lock.withLock {
            pausedHandles.append(handle)
            runningHandles.removeAll { $0 == handle }
        }
        return Data("resume".utf8)
    }

    func cancel(_ handle: DownloadTaskHandle) async {
        lock.withLock {
            cancelledHandles.append(handle)
            runningHandles.removeAll { $0 == handle }
        }
    }

    func reattach() async -> [DownloadTaskHandle] {
        lock.withLock { runningHandles }
    }
}

private final class FakeNetwork: NetworkPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private var current: NetworkStatus
    private var continuations: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]

    init(_ status: NetworkStatus) { current = status }

    var status: NetworkStatus { lock.withLock { current } }

    var changes: AsyncStream<NetworkStatus> {
        AsyncStream { continuation in
            lock.withLock {
                continuations[UUID()] = continuation
                continuation.yield(current)
            }
        }
    }

    func set(_ status: NetworkStatus) {
        let targets = lock.withLock { () -> [AsyncStream<NetworkStatus>.Continuation] in
            current = status
            return Array(continuations.values)
        }
        for continuation in targets { continuation.yield(status) }
    }
}

private final class FreeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64
    init(_ bytes: Int64) { self.bytes = bytes }
    var value: Int64 {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
}

private let secretUser = "SECRETUSER"
private let secretPass = "SECRETPASS"
private let secretHost = "secret-host.example"
private let testSecret = PlaylistSecret.xtream(server: URL(string: "http://\(secretHost):8080")!,
                                               username: secretUser, password: secretPass)
private let wifi = NetworkStatus(isOnline: true, isOnWifi: true)
private let cellular = NetworkStatus(isOnline: true, isOnWifi: false)

@MainActor
private struct ManagerHarness {
    let manager: DownloadManager
    let transport: FakeTransport
    let network: FakeNetwork
    let broker: StreamConnectionBroker
    let store: DownloadStore
    let free: FreeBox
    let playlistID: UUID
    let profileID: UUID
    let root: URL

    func key(_ id: String = "m1", profile: UUID? = nil) -> DownloadKey {
        DownloadKey(profileID: profile ?? profileID, playlistID: playlistID, kind: .movie, providerID: id)
    }

    func snapshot(_ id: String = "m1", expected: Int64? = 100) -> DownloadSnapshot {
        DownloadSnapshot(title: "Film \(id)", container: "mp4",
                         locator: .xtream(kind: .movie, streamID: id, container: "mp4"), expectedBytes: expected)
    }

    func state(of key: DownloadKey) -> DownloadState? {
        manager.items.first { $0.key == key }?.state
    }

    func item(_ key: DownloadKey) -> StoredDownload? {
        manager.items.first { $0.key == key }
    }

    func stagedFile(bytes: Int) throws -> URL {
        let dir = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 9, count: bytes).write(to: url)
        return url
    }

    func finish(_ handle: DownloadTaskHandle, bytes: Int = 200, status: Int = 200,
                contentType: String? = "video/mp4") throws -> URL {
        let file = try stagedFile(bytes: bytes)
        transport.emit(.finished(handle, stagedFile: file, status: status, contentType: contentType))
        return file
    }

    func cleanUp() {
        manager.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeHarness(network status: NetworkStatus = wifi, freeBytes: Int64 = 100_000_000_000,
                         start: Bool = true, settle: Duration = .milliseconds(20)) async throws -> ManagerHarness {
    let db = try AppDatabase.inMemory()
    let playlistID = UUID()
    try LibraryStore(db: db).upsertPlaylist(
        Playlist(id: playlistID, name: "A", kind: .xtream, createdAt: Date(timeIntervalSince1970: 1000)))
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("download-manager-tests-\(UUID().uuidString)", isDirectory: true)
    let store = DownloadStore(db: db, directory: root.appendingPathComponent("store", isDirectory: true))
    let broker = StreamConnectionBroker()
    await broker.setLimit(1, playlistID: playlistID)
    let transport = FakeTransport()
    let network = FakeNetwork(status)
    let free = FreeBox(freeBytes)
    let manager = DownloadManager(
        store: store, transport: transport, broker: broker, network: network,
        freeSpace: { free.value }, secret: { _ in testSecret }, retryInterval: .milliseconds(30),
        networkSettleTimeout: settle)
    if start { await manager.start() }
    return ManagerHarness(manager: manager, transport: transport, network: network, broker: broker, store: store,
                   free: free, playlistID: playlistID, profileID: UUID(), root: root)
}

/// Väntar tills villkoret gäller (högst `timeout`).
@MainActor
private func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - Tester

@MainActor
struct DownloadManagerTests {
    @Test func enqueueAcquiresDownloadLeaseAndStarts() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        #expect(h.transport.started.count == 1)
        #expect(h.transport.started.first?.key == key)
        #expect(h.transport.started.first?.allowsCellular == false)
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 1)
        #expect(h.state(of: key) == .downloading(progress: 0))
    }

    @Test func noFreeSlotQueuesThenStartsOnRelease() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let playback = try #require(await h.broker.acquire(.playback, playlistID: h.playlistID) {})
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        #expect(h.transport.started.isEmpty)
        #expect(h.state(of: key) == .paused(.connectionNeeded))
        await h.broker.release(playback)
        #expect(await eventually { h.transport.started.count == 1 })
        #expect(await eventually { h.state(of: key) == .downloading(progress: 0) })
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 1)
    }

    @Test func playbackRevokePausesAndSavesResumeData() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        let playback = await h.broker.acquire(.playback, playlistID: h.playlistID) {}
        #expect(playback != nil)
        #expect(h.transport.paused.count == 1)
        #expect(h.state(of: key) == .paused(.connectionNeeded))
        #expect(try h.store.resumeData(for: key) == Data("resume".utf8))
        // Bara uppspelningen äger platsen nu.
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 1)
        if let playback { await h.broker.release(playback) }
    }

    @Test func afterPlaybackReleaseResumesAutomatically() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        let playback = try #require(await h.broker.acquire(.playback, playlistID: h.playlistID) {})
        #expect(h.state(of: key) == .paused(.connectionNeeded))
        await h.broker.release(playback)
        #expect(await eventually { h.transport.started.count == 2 })
        #expect(h.transport.started.last?.resumeData == Data("resume".utf8))
        #expect(await eventually { h.state(of: key) == .downloading(progress: 0) })
    }

    @Test func userPauseNotAutoResumed() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        await h.manager.pause(key)
        #expect(h.state(of: key) == .paused(.user))
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 0)
        let playback = try #require(await h.broker.acquire(.playback, playlistID: h.playlistID) {})
        await h.broker.release(playback)
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.state(of: key) == .paused(.user))
        #expect(h.transport.started.count == 1)
        // Användaren återupptar själv.
        await h.manager.resume(key)
        #expect(h.transport.started.count == 2)
        #expect(h.state(of: key) == .downloading(progress: 0))
    }

    @Test func badStatusMarksFailedAndDeletesTemp() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        let handle = try #require(h.transport.handles.first)
        let staged = try h.finish(handle, status: 404, contentType: "video/mp4")
        #expect(await eventually { h.state(of: key) == .failed(.badStatus) })
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 0)
        #expect(try h.store.download(for: key)?.state == .failed(.badStatus))
        #expect(try h.store.download(for: key)?.fileURL == nil)
    }

    @Test func htmlContentTypeMarksBadContent() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        let handle = try #require(h.transport.handles.first)
        let staged = try h.finish(handle, contentType: "text/html; charset=utf-8")
        #expect(await eventually { h.state(of: key) == .failed(.badContent) })
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try h.store.download(for: key)?.fileURL == nil)
    }

    @Test func tooSmallFileMarksBadContent() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        // Förväntat 100 byte ger minimum 50; filen är 10 byte.
        try await h.manager.enqueue(h.snapshot(expected: 100), key: key)
        let handle = try #require(h.transport.handles.first)
        let staged = try h.finish(handle, bytes: 10)
        #expect(await eventually { h.state(of: key) == .failed(.badContent) })
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try h.store.download(for: key)?.state == .failed(.badContent))
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 0)
    }

    @Test func unauthorizedMarksExpired() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        let handle = try #require(h.transport.handles.first)
        _ = try h.finish(handle, status: 401, contentType: nil)
        #expect(await eventually { h.state(of: key) == .failed(.expired) })
        try await h.manager.enqueue(h.snapshot("m2"), key: h.key("m2"))
        let second = try #require(h.transport.handles.last)
        _ = try h.finish(second, status: 403, contentType: "text/html")
        #expect(await eventually { h.state(of: h.key("m2")) == .failed(.expired) })
    }

    @Test func lowSpacePausesBeforeStart() async throws {
        // 600 MB ledigt är över tröskeln (500 MB) men rymmer inte 1 GB.
        let h = try await makeHarness(freeBytes: 600_000_000)
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(expected: 1_000_000_000), key: key)
        #expect(h.state(of: key) == .paused(.lowDiskSpace))
        #expect(h.transport.started.isEmpty)
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 0)
        // Mer utrymme: återupptas av sig själv.
        h.free.value = 50_000_000_000
        #expect(await eventually { h.transport.started.count == 1 })
        #expect(await eventually { h.state(of: key) == .downloading(progress: 0) })
    }

    @Test func cellularPausesWhenWifiOnlyAndResumesOnWifi() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        h.network.set(cellular)
        #expect(await eventually { h.state(of: key) == .paused(.waitingForWifi) })
        #expect(h.transport.paused.count == 1)
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 0)
        h.network.set(wifi)
        #expect(await eventually { h.transport.started.count == 2 })
        #expect(h.transport.started.last?.resumeData == Data("resume".utf8))
        #expect(await eventually { h.state(of: key) == .downloading(progress: 0) })
    }

    @Test func wifiOnlyOffAllowsCellular() async throws {
        let h = try await makeHarness(network: cellular)
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        #expect(h.transport.started.isEmpty)
        await h.manager.configure(DownloadSettings(wifiOnly: false))
        #expect(h.transport.started.count == 1)
        #expect(h.transport.started.first?.allowsCellular == true)
    }

    @Test func finishedMovesFileAndReleasesLease() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        let handle = try #require(h.transport.handles.first)
        h.transport.emit(.progress(handle, bytesWritten: 50, totalBytes: 100))
        #expect(await eventually { h.item(key)?.bytesWritten == 50 })
        let staged = try h.finish(handle)
        #expect(await eventually { h.state(of: key) == .completed })
        let file = try #require(h.item(key)?.fileURL)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try h.store.download(for: key)?.state == .completed)
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 0)
    }

    @Test func reattachAdoptsRunningTasksOnLaunch() async throws {
        let h = try await makeHarness(start: false)
        defer { h.cleanUp() }
        let key = h.key()
        try h.store.insert(h.snapshot(), key: key)
        try h.store.updateState(.downloading(progress: 0.5), bytesWritten: 50, for: key)
        let handle = DownloadTaskHandle(key: key, taskID: 77)
        h.transport.addRunning(handle)
        // Ett föräldralöst system-task för en okänd titel avbryts.
        let stray = DownloadTaskHandle(key: h.key("okand"), taskID: 78)
        h.transport.addRunning(stray)

        await h.manager.start()
        #expect(h.transport.started.isEmpty)
        #expect(h.transport.cancelled == [stray])
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 1)
        guard case .downloading = h.state(of: key) else {
            Issue.record("förväntade downloading, fick \(String(describing: h.state(of: key)))")
            return
        }
        h.transport.emit(.progress(handle, bytesWritten: 60, totalBytes: 100))
        #expect(await eventually { h.item(key)?.bytesWritten == 60 })
        _ = try h.finish(handle)
        #expect(await eventually { h.state(of: key) == .completed })
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 0)
    }

    @Test func becomingActiveWithPlaybackLeaseCancelsDownloads() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        let handle = try #require(h.transport.handles.first)
        let playback = try #require(await h.broker.acquire(.playback, playlistID: h.playlistID) {})
        #expect(h.transport.paused == [handle])
        // Systemet har ändå fortsatt överföringen (bakgrundssessionen) utan att vi har en lease.
        h.transport.addRunning(handle)
        await h.manager.applicationDidBecomeActive()
        #expect(h.transport.paused == [handle, handle])
        #expect(h.transport.started.count == 1)
        #expect(h.state(of: key) == .paused(.connectionNeeded))
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 1)
        await h.broker.release(playback)
    }

    @Test func becomingActiveCancelsUnknownTasks() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let stray = DownloadTaskHandle(key: h.key("okand"), taskID: 5)
        h.transport.addRunning(stray)
        await h.manager.applicationDidBecomeActive()
        #expect(h.transport.cancelled == [stray])
    }

    @Test func staleResumeDataIsClearedAndRetryStartsFresh() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        await h.manager.pause(key)
        #expect(try h.store.resumeData(for: key) != nil)
        await h.manager.resume(key)
        #expect(h.transport.started.last?.resumeData == Data("resume".utf8))
        // Lämnad till transporten: borta ur lagret.
        #expect(try h.store.resumeData(for: key) == nil)
        let handle = try #require(h.transport.handles.last)
        _ = try h.finish(handle, status: 401, contentType: nil)
        #expect(await eventually { h.state(of: key) == .failed(.expired) })
        #expect(try h.store.resumeData(for: key) == nil)
        await h.manager.resume(key)
        #expect(h.transport.started.count == 3)
        #expect(h.transport.started.last?.resumeData == nil)
    }

    @Test func adoptedTaskKeptWhenNetworkIsWifiAtLoad() async throws {
        let h = try await makeHarness(network: wifi, start: false)
        defer { h.cleanUp() }
        let key = h.key()
        try h.store.insert(h.snapshot(), key: key)
        try h.store.updateState(.downloading(progress: 0.2), bytesWritten: 20, for: key)
        h.transport.addRunning(DownloadTaskHandle(key: key, taskID: 9))
        await h.manager.start()
        #expect(h.transport.paused.isEmpty)
        #expect(h.transport.started.isEmpty)
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 1)
    }

    @Test func lowSpaceMidDownloadPausesWithResumeData() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        let handle = try #require(h.transport.handles.first)
        h.transport.emit(.progress(handle, bytesWritten: 10, totalBytes: 100))
        #expect(await eventually { h.item(key)?.bytesWritten == 10 })
        #expect(h.transport.paused.isEmpty)
        // Utrymmet tar slut mitt i hämtningen (under reserven på 500 MB).
        h.free.value = 100_000_000
        h.transport.emit(.progress(handle, bytesWritten: 60, totalBytes: 100))
        #expect(await eventually { h.state(of: key) == .paused(.lowDiskSpace) })
        #expect(h.transport.paused == [handle])
        #expect(try h.store.resumeData(for: key) == Data("resume".utf8))
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 0)
    }

    @Test func resumeAfterLowSpaceChecksOnlyRemainingAndStaysRunning() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(expected: 1_000_000_000), key: key)
        let handle = try #require(h.transport.handles.first)
        h.transport.emit(.progress(handle, bytesWritten: 500_000_000, totalBytes: 1_000_000_000))
        #expect(await eventually { h.item(key)?.bytesWritten == 500_000_000 })
        // 900 MB hämtat; 100 MB återstår men bara 50 MB ryms över reserven.
        h.free.value = 550_000_000
        h.transport.emit(.progress(handle, bytesWritten: 900_000_000, totalBytes: 1_000_000_000))
        #expect(await eventually { h.state(of: key) == .paused(.lowDiskSpace) })
        // Nu ryms återstoden (plus marginal) men inte hela filen: ska återupptas och förbli igång.
        h.free.value = 700_000_000
        #expect(await eventually { h.transport.started.count == 2 })
        try await Task.sleep(for: .milliseconds(250))
        #expect(h.state(of: key) == .downloading(progress: 0))
        #expect(h.transport.started.count == 2)
        #expect(h.transport.paused.count == 1)
    }

    @Test func remainingBytesLargerThanFreeSpacePauses() async throws {
        let h = try await makeHarness(freeBytes: 2_000_000_000)
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        let handle = try #require(h.transport.handles.first)
        // 2 GB ledigt minus 500 MB reserv rymmer inte 3 GB som återstår.
        h.transport.emit(.progress(handle, bytesWritten: 1_000_000, totalBytes: 3_001_000_000))
        #expect(await eventually { h.state(of: key) == .paused(.lowDiskSpace) })
    }

    @Test func offlineAtLoadThenWifiWithinTimeoutKeepsAdoptedTask() async throws {
        let h = try await makeHarness(network: .offline, start: false, settle: .seconds(2))
        defer { h.cleanUp() }
        let key = h.key()
        try h.store.insert(h.snapshot(), key: key)
        try h.store.updateState(.downloading(progress: 0.2), bytesWritten: 20, for: key)
        h.transport.addRunning(DownloadTaskHandle(key: key, taskID: 9))
        let manager = h.manager
        let starting = Task { await manager.start() }
        try await Task.sleep(for: .milliseconds(100))
        h.network.set(wifi)
        await starting.value
        #expect(h.transport.paused.isEmpty)
        #expect(h.transport.started.isEmpty)
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 1)
    }

    @Test func adoptedTaskOnCellularKeptUntilSettingsApplied() async throws {
        let h = try await makeHarness(network: cellular, start: false)
        defer { h.cleanUp() }
        let key = h.key()
        try h.store.insert(h.snapshot(), key: key)
        try h.store.updateState(.downloading(progress: 0.2), bytesWritten: 20, for: key)
        h.transport.addRunning(DownloadTaskHandle(key: key, taskID: 9))
        await h.manager.start()
        // Standardvärdet (bara wifi) får inte stoppa den innan användarens inställning är känd.
        #expect(h.transport.paused.isEmpty)
        await h.manager.applicationDidBecomeActive()
        #expect(h.transport.paused.isEmpty)
        // Användaren tillåter mobildata: uppgiften behålls och får sin lease.
        await h.manager.configure(DownloadSettings(wifiOnly: false))
        #expect(h.transport.paused.isEmpty)
        #expect(h.transport.started.isEmpty)
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 1)
    }

    @Test func adoptedTaskOnCellularStoppedWhenSettingsRequireWifi() async throws {
        let h = try await makeHarness(network: cellular, start: false)
        defer { h.cleanUp() }
        let key = h.key()
        try h.store.insert(h.snapshot(), key: key)
        try h.store.updateState(.downloading(progress: 0.2), bytesWritten: 20, for: key)
        h.transport.addRunning(DownloadTaskHandle(key: key, taskID: 9))
        await h.manager.start()
        await h.manager.configure(DownloadSettings(wifiOnly: true))
        #expect(h.transport.paused.count == 1)
    }

    @Test func failureNeverContainsURLOrCredentials() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        let first = try #require(h.transport.handles.first)
        h.transport.emit(.failed(first, .network, resumeData: nil))
        #expect(await eventually { h.state(of: key) == .failed(.network) })
        await h.manager.resume(key)
        let second = try #require(h.transport.handles.last)
        _ = try h.finish(second, status: 500, contentType: "text/html")
        #expect(await eventually { h.state(of: key) == .failed(.badStatus) })

        var texts = [String(describing: h.manager.items), String(reflecting: h.manager.items),
                     String(describing: h.transport.started), String(reflecting: h.transport.started)]
        let stored = try h.store.list(profileID: h.profileID, playlistID: nil)
        texts.append(String(describing: stored))
        for text in texts {
            #expect(!text.contains(secretUser))
            #expect(!text.contains(secretPass))
            #expect(!text.contains(secretHost))
            #expect(!text.contains("http://"))
        }
        // Transporten fick hemligheten (så att den kan bygga URL:en), men den skrivs aldrig ut.
        #expect(h.transport.started.first?.secret == testSecret)
    }

    @Test func profileSwitchMidDownloadKeepsOriginalProfileRows() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let other = UUID()
        let first = h.key("m1")
        let second = h.key("m2", profile: other)
        try await h.manager.enqueue(h.snapshot("m1"), key: first)
        // En annan profil köar medan den första hämtar.
        try await h.manager.enqueue(h.snapshot("m2"), key: second)
        let handle = try #require(h.transport.handles.first)
        _ = try h.finish(handle)
        #expect(await eventually { h.state(of: first) == .completed })

        let firstRows = try h.store.list(profileID: h.profileID, playlistID: nil)
        let secondRows = try h.store.list(profileID: other, playlistID: nil)
        #expect(firstRows.map(\.key) == [first])
        #expect(secondRows.map(\.key) == [second])
        let file = try #require(firstRows.first?.fileURL)
        #expect(file.path.contains(DownloadPaths.relativeDirectory(for: first)))
        #expect(!file.path.contains(DownloadPaths.relativeDirectory(for: second)))
        // Den andra profilens rad hamnar aldrig under den första profilens nyckel.
        #expect(h.manager.items.filter { $0.key.profileID == h.profileID }.count == 1)
        #expect(await eventually { h.transport.started.last?.key == second })
    }

    @Test func cancelRemovesRowAndFiles() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let key = h.key()
        try await h.manager.enqueue(h.snapshot(), key: key)
        let handle = try #require(h.transport.handles.first)
        await h.manager.cancel(key)
        #expect(h.transport.cancelled == [handle])
        #expect(h.item(key) == nil)
        #expect(try h.store.download(for: key) == nil)
        #expect(await h.broker.activeCount(playlistID: h.playlistID) == 0)
    }

    @Test func backgroundEventsFinishedCompletesSessionHandler() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        var completed = 0
        DownloadSessionEvents.shared.store { completed += 1 }
        h.transport.emit(.backgroundEventsFinished)
        #expect(await eventually { completed == 1 })
    }
}

@MainActor
struct DownloadSessionEventsTests {
    @Test func handlerRunsOnceWhenCompleted() {
        let events = DownloadSessionEvents()
        var calls = 0
        events.store { calls += 1 }
        #expect(events.hasPendingHandler)
        events.complete()
        events.complete()
        #expect(calls == 1)
        #expect(!events.hasPendingHandler)
    }

    @Test func completionBeforeHandlerRunsHandlerImmediately() {
        let events = DownloadSessionEvents()
        var calls = 0
        events.complete()
        events.store { calls += 1 }
        #expect(calls == 1)
        #expect(!events.hasPendingHandler)
    }

    @Test func resetLatchPreventsEarlyCompletionLeak() {
        let events = DownloadSessionEvents()
        var calls = 0
        events.complete()
        events.resetLatch()
        events.store { calls += 1 }
        #expect(calls == 0)
        #expect(events.hasPendingHandler)
    }

    @Test func replacedHandlerIsCalledFirst() {
        let events = DownloadSessionEvents()
        var order: [Int] = []
        events.store { order.append(1) }
        events.store { order.append(2) }
        events.complete()
        #expect(order == [1, 2])
    }
}

struct TransportTaskDescriptionTests {
    @Test func keyRoundTripsEvenWithSeparatorInProviderID() {
        let key = DownloadKey(profileID: UUID(), playlistID: UUID(), kind: .series, providerID: "a|b|c")
        let text = BackgroundDownloadTransport.describe(key)
        #expect(BackgroundDownloadTransport.key(from: text) == key)
    }

    @Test func garbageDescriptionGivesNil() {
        #expect(BackgroundDownloadTransport.key(from: nil) == nil)
        #expect(BackgroundDownloadTransport.key(from: "x|y|z") == nil)
        #expect(BackgroundDownloadTransport.key(from: "\(UUID())|\(UUID())|bogus|id") == nil)
    }
}
#endif
