#if !os(tvOS)
import Core
import Downloads
import Foundation
import Library
import Playback
import PlaybackCore
import Providers
import ProvidersTestSupport
import Testing
@testable import IPTVApp

// MARK: - Fakes

private final class QuietTransport: DownloadTransport, @unchecked Sendable {
    let events: AsyncStream<DownloadTransportEvent> = AsyncStream<DownloadTransportEvent>.makeStream().stream
    func start(_ request: DownloadTransportRequest) async throws -> DownloadTaskHandle {
        DownloadTaskHandle(key: request.key, taskID: 1)
    }
    func pause(_ handle: DownloadTaskHandle) async -> Data? { nil }
    func cancel(_ handle: DownloadTaskHandle) async {}
    func reattach() async -> [DownloadTaskHandle] { [] }
}

private final class QuietNetwork: NetworkPolicy, @unchecked Sendable {
    let status = NetworkStatus(isOnline: true, isOnWifi: true)
    var changes: AsyncStream<NetworkStatus> { AsyncStream { $0.yield(status) } }
}

// MARK: - Uppsättning

@MainActor
private struct Fixture {
    let model: AppModel
    let store: DownloadStore
    let manager: DownloadManager
    let playlistID: UUID
    let profileID: UUID
    let root: URL

    func viewModel(freeBytes: @escaping @Sendable () -> Int64 = { 1_000_000 },
                   playing: @escaping @MainActor () -> ProgressKey? = { nil }) -> DownloadsViewModel {
        DownloadsViewModel(model: model, manager: manager, freeBytes: freeBytes, playing: playing)
    }

    func key(_ kind: ContentKind, _ id: String) -> DownloadKey {
        DownloadKey(profileID: profileID, playlistID: playlistID, kind: kind, providerID: id)
    }
}

private enum Seed {
    case completed(bytes: Int)
    case paused(bytes: Int64)
    case failed
}

/// En rad att lägga i lagret innan hanteraren startas.
private struct SeedRow {
    var kind: ContentKind
    var id: String
    var title: String
    var seed: Seed
    var season: Int?
    var episode: Int?
    var seriesID: String?
    var seriesTitle: String?
    var order: Int = 0

    static func movie(_ id: String, _ title: String, _ seed: Seed, order: Int = 0) -> SeedRow {
        SeedRow(kind: .movie, id: id, title: title, seed: seed, order: order)
    }

    static func episode(_ id: String, season: Int, number: Int, _ seed: Seed = .completed(bytes: 64)) -> SeedRow {
        SeedRow(kind: .series, id: id, title: "Avsnitt \(number)", seed: seed, season: season, episode: number,
                seriesID: "5", seriesTitle: "Serie")
    }
}

/// Modell med vuxenprofil och en nedladdningshanterare (tyst transport) som startats efter att raderna lagts in.
@MainActor
private func makeFixture(_ rows: [SeedRow] = []) async throws -> Fixture {
    let db = try AppDatabase.inMemory()
    let model = AppModel(store: LibraryStore(db: db), credentials: InMemoryCredentialStore(),
                         http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults(),
                         userState: InMemoryUserStateStore())
    await model.addPlaylist(name: "Min", secret: xtreamSecret)
    let playlistID = try #require(model.playlists.first?.id)
    model.enter(playlistID: playlistID)
    let profileID = try #require(model.activeProfile?.profile.id)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("downloads-vm-tests-\(UUID().uuidString)", isDirectory: true)
    let store = DownloadStore(db: db, directory: root.appendingPathComponent("store", isDirectory: true))
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    for row in rows {
        let key = DownloadKey(profileID: profileID, playlistID: playlistID, kind: row.kind, providerID: row.id)
        let snapshot = DownloadSnapshot(
            title: row.title, season: row.season, episode: row.episode, container: "mkv",
            seriesProviderID: row.seriesID, seriesTitle: row.seriesTitle,
            locator: .xtream(kind: row.kind, streamID: row.id, container: "mkv"),
            addedAt: Date(timeIntervalSince1970: 1_000 + Double(row.order)))
        _ = try store.insert(snapshot, key: key)
        switch row.seed {
        case let .completed(bytes):
            let temp = staging.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 7, count: bytes).write(to: temp)
            _ = try store.completeMoving(from: temp, for: key, expectedMinBytes: 1)
        case let .paused(bytes):
            try store.updateState(.paused(.user), bytesWritten: bytes, for: key)
        case .failed:
            try store.updateState(.failed(.noSpace), bytesWritten: 0, for: key)
        }
    }

    let manager = DownloadManager(
        store: store, transport: QuietTransport(), broker: StreamConnectionBroker(), network: QuietNetwork(),
        freeSpace: { 100_000_000_000 }, secret: { _ in throw CoreError.missingSecret })
    await manager.start()
    model.downloadStore = store
    model.downloadManager = manager
    return Fixture(model: model, store: store, manager: manager, playlistID: playlistID, profileID: profileID,
                   root: root)
}

@MainActor
private func row(_ vm: DownloadsViewModel, _ id: String) -> DownloadsViewModel.Row? {
    vm.sections.flatMap(\.rows).first { $0.key.providerID == id }
}

// MARK: - Tester

@MainActor
struct DownloadsViewModelTests {
    @Test func sectionsGroupSeriesAndPutActiveFirst() async throws {
        let f = try await makeFixture([
            .movie("2", "B Film", .completed(bytes: 10)),
            .movie("1", "A Film", .completed(bytes: 10)),
            .movie("3", "Pågående film", .paused(bytes: 5), order: 5),
            .episode("503", season: 2, number: 1),
            .episode("502", season: 1, number: 2),
            .episode("501", season: 1, number: 1),
        ])
        defer { try? FileManager.default.removeItem(at: f.root) }
        let sections = f.viewModel().sections

        #expect(sections.map(\.id) == ["active", "movies", "series/5/1", "series/5/2"])
        #expect(sections[0].rows.map(\.title) == ["Pågående film"])
        #expect(sections[1].rows.map(\.title) == ["A Film", "B Film"])
        #expect(sections[2].rows.map(\.key.providerID) == ["501", "502"])
        #expect(sections[3].rows.map(\.key.providerID) == ["503"])
        // Stabila id:n över omräkningar.
        #expect(f.viewModel().sections.flatMap(\.rows).map(\.id) == sections.flatMap(\.rows).map(\.id))
    }

    @Test func statesMapToReadableRows() async throws {
        typealias VM = DownloadsViewModel
        #expect(VM.state(for: .queued) == .queued)
        #expect(VM.state(for: .downloading(progress: 0.5)) == .downloading)
        #expect(VM.state(for: .paused(.user)) == .pausedByUser)
        #expect(VM.state(for: .paused(.waitingForWifi)) == .waitingForWifi)
        #expect(VM.state(for: .paused(.connectionNeeded)) == .pausedForPlayback)
        #expect(VM.state(for: .paused(.lowDiskSpace)) == .lowDiskSpace)
        #expect(VM.state(for: .completed) == .completed)
        #expect(VM.state(for: .failed(.expired)) == .failed(.expired))

        #expect(VM.statusText(for: .waitingForWifi) == String(localized: "Waiting for Wi-Fi"))
        #expect(VM.statusText(for: .pausedForPlayback) == String(localized: "Paused – playback in progress"))
        #expect(VM.statusText(for: .lowDiskSpace) == String(localized: "Out of space"))

        // Alla texter är ifyllda och skilda åt, utom "slut på utrymme" som medvetet delas av pausen och felet.
        let failures: [DownloadFailure] = [.badStatus, .badContent, .noSpace, .storage, .expired, .network, .unknown]
        let states: [VM.RowState] = [.queued, .downloading, .pausedByUser, .waitingForWifi, .pausedForPlayback,
                                     .lowDiskSpace, .completed] + failures.map { .failed($0) }
        let texts = states.map { VM.statusText(for: $0) }
        #expect(texts.allSatisfy { !$0.isEmpty })
        #expect(Set(texts).count == texts.count - 1)

        // Åtgärder per tillstånd; det som spelas får varken raderas eller avbrytas.
        #expect(VM.actions(for: .completed, canPlay: true, protected: false) == [.play, .delete])
        #expect(VM.actions(for: .completed, canPlay: true, protected: true) == [.play])
        #expect(VM.actions(for: .downloading, canPlay: false, protected: false) == [.pause, .cancel])
        #expect(VM.actions(for: .pausedByUser, canPlay: false, protected: false) == [.resume, .cancel])
        #expect(VM.actions(for: .failed(.network), canPlay: false, protected: false) == [.resume, .cancel])
        #expect(VM.actions(for: .waitingForWifi, canPlay: false, protected: false) == [.cancel])
    }

    @Test func rowsCarryProgressSizeAndPlayability() async throws {
        let f = try await makeFixture([.movie("1", "Klar", .completed(bytes: 64)),
                                       .movie("2", "Pausad", .paused(bytes: 10), order: 1)])
        defer { try? FileManager.default.removeItem(at: f.root) }
        let vm = f.viewModel()
        let done = try #require(row(vm, "1"))
        #expect(done.canPlay)
        #expect(done.state == .completed)
        #expect(done.sizeText == DownloadsViewModel.sizeString(64))
        let paused = try #require(row(vm, "2"))
        #expect(!paused.canPlay)
        #expect(paused.state == .pausedByUser)
        #expect(paused.actions == [.resume, .cancel])
    }

    @Test func kidsGetsEmptyAndNoTab() async throws {
        let f = try await makeFixture([.movie("1", "Film", .completed(bytes: 10))])
        defer { try? FileManager.default.removeItem(at: f.root) }
        let vm = f.viewModel()
        let adultRow = try #require(row(vm, "1"))
        #expect(!vm.isEmpty)

        let kid = try f.model.addProfile(playlistID: f.playlistID, name: "Barn", avatar: "pawprint.fill", isKids: true)
        try await f.model.select(profile: kid, pin: nil)
        #expect(!f.model.downloadsAvailable)
        #expect(vm.sections.isEmpty)
        #expect(vm.isEmpty)
        await vm.perform(.play, on: adultRow)
        #expect(vm.presented == nil)
        await vm.perform(.delete, on: adultRow)
        #expect(f.manager.items.count == 1)
    }

    @Test func playActionBuildsOfflineRequest() async throws {
        let f = try await makeFixture([.movie("1", "Film", .completed(bytes: 64))])
        defer { try? FileManager.default.removeItem(at: f.root) }
        let vm = f.viewModel()
        let r = try #require(row(vm, "1"))
        let file = try #require(f.manager.items.first?.fileURL)
        await vm.perform(.play, on: r)
        let request = try #require(vm.presented?.request)
        #expect(request.localURL == file)
        #expect(!request.isLive)
        #expect(vm.message == nil)
    }

    @Test func playActionOnMissingFileShowsReadableError() async throws {
        let f = try await makeFixture([.movie("1", "Film", .completed(bytes: 64))])
        defer { try? FileManager.default.removeItem(at: f.root) }
        let vm = f.viewModel()
        let r = try #require(row(vm, "1"))
        try FileManager.default.removeItem(at: try #require(f.manager.items.first?.fileURL))
        await vm.perform(.play, on: r)
        #expect(vm.presented == nil)
        #expect(vm.message == UserFacingError.message(for: OfflinePlaybackError.fileMissing))
        #expect(vm.message != UserFacingError.message(for: CancellationError()))
    }

    @Test func deleteActionRemovesRowAndFile() async throws {
        let f = try await makeFixture([.movie("1", "Film", .completed(bytes: 64))])
        defer { try? FileManager.default.removeItem(at: f.root) }
        let vm = f.viewModel()
        let r = try #require(row(vm, "1"))
        let file = try #require(f.manager.items.first?.fileURL)
        #expect(FileManager.default.fileExists(atPath: file.path))
        await vm.perform(.delete, on: r)
        #expect(vm.isEmpty)
        #expect(row(vm, "1") == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try f.store.download(for: f.key(.movie, "1")) == nil)
    }

    @Test func totalAndFreeSpaceText() async throws {
        let f = try await makeFixture([.movie("1", "Film", .completed(bytes: 64)),
                                       .movie("2", "Pausad", .paused(bytes: 36), order: 1)])
        defer { try? FileManager.default.removeItem(at: f.root) }
        let vm = f.viewModel(freeBytes: { 5_000_000_000 })
        let total = DownloadsViewModel.sizeString(100)
        #expect(vm.totalSizeText == String(localized: "\(total) used"))
        #expect(vm.freeSpaceText.isEmpty)
        await vm.refresh()
        let free = DownloadsViewModel.sizeString(5_000_000_000)
        #expect(vm.freeSpaceText == String(localized: "\(free) free"))
    }

    @Test func emptyState() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let vm = f.viewModel()
        #expect(vm.isEmpty)
        #expect(vm.sections.isEmpty)
        let zero = DownloadsViewModel.sizeString(0)
        #expect(vm.totalSizeText == String(localized: "\(zero) used"))
    }

    @Test func deletingPlayingItemIsBlocked() async throws {
        let f = try await makeFixture([.movie("1", "Film", .completed(bytes: 64)),
                                       .movie("2", "Annan", .completed(bytes: 64), order: 1),
                                       .episode("501", season: 1, number: 1),
                                       .episode("502", season: 1, number: 2)])
        defer { try? FileManager.default.removeItem(at: f.root) }
        let vm = f.viewModel()
        let playing = try #require(row(vm, "1"))
        let file = try #require(f.manager.items.first { $0.key.providerID == "1" }?.fileURL)
        await vm.perform(.play, on: playing)
        try #require(vm.presented != nil)

        // Det som spelas går inte att radera; raden saknar åtgärden och försöket ger en förklaring.
        let during = try #require(row(vm, "1"))
        #expect(!during.actions.contains(.delete))
        await vm.perform(.delete, on: during)
        #expect(row(vm, "1") != nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(vm.message == String(localized: "Stop playback before deleting this download."))
        // En annan film rörs inte av spärren.
        await vm.perform(.delete, on: try #require(row(vm, "2")))
        #expect(row(vm, "2") == nil)

        // När spelaren stängts går raderingen igenom.
        vm.presented = nil
        vm.message = nil
        await vm.perform(.delete, on: try #require(row(vm, "1")))
        #expect(row(vm, "1") == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func playingKeyFromOutsideBlocksDeletionOfThatEpisodesSeries() async throws {
        let f = try await makeFixture([.episode("501", season: 1, number: 1), .episode("502", season: 1, number: 2)])
        defer { try? FileManager.default.removeItem(at: f.root) }
        let current = ProgressKey(playlistID: f.playlistID, kind: .series, providerID: "501", seriesProviderID: "5")
        let vm = f.viewModel(playing: { current })
        // Nästa avsnitt kan ha tagit över i spelaren: hela serien är spärrad.
        await vm.perform(.delete, on: try #require(row(vm, "502")))
        #expect(row(vm, "502") != nil)
        #expect(vm.message != nil)

        let free = f.viewModel()
        await free.perform(.delete, on: try #require(row(free, "502")))
        #expect(row(free, "502") == nil)
    }
}
#endif
