#if !os(tvOS)
import Core
import Downloads
import Foundation
import GRDB
import Library
import Providers
import ProvidersTestSupport
import Testing
@testable import IPTVApp

// MARK: - Fakes

private final class ControlledNetwork: NetworkPolicy, @unchecked Sendable {
    private let lock = NSLock()
    private var current: NetworkStatus
    private var continuations: [AsyncStream<NetworkStatus>.Continuation] = []

    init(_ status: NetworkStatus) { current = status }

    var status: NetworkStatus { lock.withLock { current } }

    var changes: AsyncStream<NetworkStatus> {
        AsyncStream { continuation in
            lock.withLock {
                continuations.append(continuation)
                continuation.yield(current)
            }
        }
    }

    func set(_ status: NetworkStatus) {
        let targets = lock.withLock { () -> [AsyncStream<NetworkStatus>.Continuation] in
            current = status
            return continuations
        }
        for target in targets { target.yield(status) }
    }
}

/// Klocka utan riktig väntan: varje `sleep` parkeras tills testet anropar `fire()`; avbrutna sovare kastar.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    var waiting: Int { lock.withLock { waiters.count } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Låter all väntan löpa ut (3 s har gått).
    func fire() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        for continuation in all { continuation.resume() }
    }
}

private final class IdleTransport: DownloadTransport, @unchecked Sendable {
    let events = AsyncStream<DownloadTransportEvent>.makeStream().stream
    func start(_ request: DownloadTransportRequest) async throws -> DownloadTaskHandle {
        DownloadTaskHandle(key: request.key, taskID: 1)
    }
    func pause(_ handle: DownloadTaskHandle) async -> Data? { nil }
    func cancel(_ handle: DownloadTaskHandle) async {}
    func reattach() async -> [DownloadTaskHandle] { [] }
}

private let online = NetworkStatus(isOnline: true, isOnWifi: true)

/// Ger tillbaka kontrollen till huvudaktören tills villkoret gäller (ingen riktig väntan).
@MainActor
private func settle(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
}

@MainActor
private func makeState(_ network: ControlledNetwork, _ clock: ManualClock) async -> OfflineState {
    let state = OfflineState(network: network, sleep: { try await clock.sleep($0) })
    await settle { state.statusUpdates >= 1 }
    return state
}

// MARK: - Tester

@MainActor
struct OfflineStateTests {
    @Test func offlineStateDebouncesShortLoss() async {
        let network = ControlledNetwork(online), clock = ManualClock()
        let state = await makeState(network, clock)
        #expect(!state.isOffline)

        // Kort bortfall: går offline, väntan startar, men nätet kommer tillbaka innan tiden gått.
        network.set(.offline)
        await settle { state.statusUpdates >= 2 && clock.waiting == 1 }
        #expect(clock.waiting == 1)
        #expect(!state.isOffline)
        network.set(online)
        await settle { state.statusUpdates >= 3 && clock.waiting == 0 }
        clock.fire()
        await Task.yield()
        #expect(!state.isOffline)
        #expect(clock.waiting == 0)

        // Bestående bortfall: offline först när tiden gått.
        network.set(.offline)
        await settle { state.statusUpdates >= 4 && clock.waiting == 1 }
        #expect(!state.isOffline)
        clock.fire()
        await settle { state.isOffline }
        #expect(state.isOffline)
    }

    @Test func onlineClearsBanner() async {
        let network = ControlledNetwork(.offline), clock = ManualClock()
        let state = await makeState(network, clock)
        await settle { clock.waiting == 1 }
        clock.fire()
        await settle { state.isOffline }
        #expect(state.isOffline)

        // Tillbaka online: bannern försvinner direkt, utan väntan.
        network.set(NetworkStatus(isOnline: true, isOnWifi: false))
        await settle { !state.isOffline }
        #expect(!state.isOffline)
    }

    @Test func offlineSuppressesNetworkErrorToasts() async throws {
        let network = ControlledNetwork(.offline), clock = ManualClock()
        let model = AppModel(store: LibraryStore(db: try AppDatabase.inMemory()), credentials: InMemoryCredentialStore(),
                             http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults())
        let state = await makeState(network, clock)
        model.offlineState = state

        // Online (innan hysteresen löpt ut): felet visas.
        model.presentError(ProviderError.unreachable)
        #expect(model.lastError != nil)
        model.lastError = nil

        await settle { clock.waiting == 1 }
        clock.fire()
        await settle { state.isOffline }
        #expect(state.isOffline)

        // Offline: nätverksfel tystas, övriga fel visas.
        model.presentError(ProviderError.unreachable)
        model.presentError(URLError(.notConnectedToInternet))
        #expect(model.lastError == nil)
        model.presentError(ProviderError.unauthorized)
        #expect(model.lastError == UserFacingError.message(for: ProviderError.unauthorized))
        model.lastError = nil
        model.presentError(PlaybackLookupError.notAllowed)
        #expect(model.lastError != nil)
    }

    @Test func reportSuppressesNetworkErrorsOnlyWhileOffline() async throws {
        let network = ControlledNetwork(.offline), clock = ManualClock()
        let model = AppModel(store: LibraryStore(db: try AppDatabase.inMemory()), credentials: InMemoryCredentialStore(),
                             http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults())
        let state = await makeState(network, clock)
        model.offlineState = state

        // Online (hysteresen har inte löpt ut): URLError visas via report.
        model.report(URLError(.notConnectedToInternet))
        #expect(model.lastError != nil)
        model.lastError = nil

        await settle { clock.waiting == 1 }
        clock.fire()
        await settle { state.isOffline }

        model.report(URLError(.notConnectedToInternet))
        model.report(ProviderError.unreachable)
        #expect(model.lastError == nil)
        model.report(ImportError.storageFailed)
        #expect(model.lastError == UserFacingError.message(for: ImportError.storageFailed))
    }

    @Test func kidsStillGatedWhenOffline() async throws {
        let network = ControlledNetwork(.offline), clock = ManualClock()
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-state-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: LibraryStore(db: db), credentials: InMemoryCredentialStore(),
                             http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults())
        await model.addPlaylist(name: "Min", secret: xtreamSecret)
        let playlistID = try #require(model.playlists.first?.id)
        model.attachDownloads(store: DownloadStore(db: db, directory: root), transport: IdleTransport(),
                              network: network, freeSpace: { 100_000_000_000 })
        // Byt ut den riktiga klockan mot den styrda och låt offline gälla.
        let state = await makeState(network, clock)
        model.offlineState = state
        await settle { clock.waiting == 1 }
        clock.fire()
        await settle { state.isOffline }
        #expect(state.isOffline)
        let kid = try model.addProfile(playlistID: playlistID, name: "Barn", avatar: "pawprint.fill", isKids: true)
        try await model.select(profile: kid, pin: nil)

        // Offline ändrar inte behörigheten: barnprofilen har fortfarande inga nedladdningar.
        #expect(model.kidsRestricted)
        #expect(!model.downloadsAvailable)
        await #expect(throws: DownloadAPIError.notAllowed) {
            try await model.downloadMovie(providerID: "101", playlistID: playlistID)
        }
    }
}
#endif
