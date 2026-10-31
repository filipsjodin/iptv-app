import Core
import Foundation
import Library
import Metadata
import Playback
import PlaybackCore
import Providers
import ProvidersTestSupport
import Testing
@testable import IPTVApp

// MARK: - Testverktyg

/// Klocka som testet styr: `sleep` väntar tills `advance` passerat tidpunkten, och kastar `CancellationError`
/// när den anropande tasken avbryts.
@MainActor
private final class ManualSleeper {
    private struct Waiter {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private(set) var now: Duration = .zero
    private var waiters: [Waiter] = []
    /// Alla begärda väntetider i ordning.
    private(set) var requested: [Duration] = []

    var pendingCount: Int { waiters.count }

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        let id = UUID()
        let deadline = now + duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, deadline: deadline, continuation: c))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func advance(by duration: Duration) {
        now += duration
        let due = waiters.filter { $0.deadline <= now }
        waiters.removeAll { $0.deadline <= now }
        for waiter in due { waiter.continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Skriptbar motor för förhandsvisningen. `PlaybackTestSupport.FakeEngine` länkas inte in i testbundeln (se
/// `TestEngine` i `PlayerScreenModelTests`), så den här har samma beteende: `.hang` hänger i `load` tills
/// `close()` anropas eller tasken avbryts. Med `holdClose` väntar `closeAndWait()` tills testet släpper den
/// (långsam teardown).
@MainActor
private final class PreviewTestEngine: PlayerEngine {
    enum Mode { case succeed, hang, fail(PlaybackFailure) }

    let kind: EngineKind = .avPlayer
    private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var currentTime: Double = 0
    private(set) var duration: Double?
    let audioTracks: [MediaTrack] = []
    let subtitleTracks: [MediaTrack] = []
    let selectedAudioID: String? = nil
    let selectedSubtitleID: String? = nil
    let videoInfo: VideoInfo = .unknown
    var onStateChange: ((PlaybackState) -> Void)?

    let mode: Mode
    let holdClose: Bool
    let log: PreviewEventLog
    var muted = false
    private(set) var loadCount = 0
    private(set) var loadedStartAt: Double?
    private(set) var pauseCount = 0
    private(set) var closeAndWaitCount = 0
    private(set) var closeFinished = false
    private var hanging: CheckedContinuation<Void, any Error>?
    private var closeGate: CheckedContinuation<Void, Never>?

    init(mode: Mode, holdClose: Bool, log: PreviewEventLog) {
        self.mode = mode
        self.holdClose = holdClose
        self.log = log
    }

    var isWaitingInClose: Bool { closeGate != nil }

    func load(url: URL, startAt: Double?) async throws {
        loadCount += 1
        loadedStartAt = startAt
        log.events.append("load")
        state = .loading
        switch mode {
        case .succeed:
            duration = 6000
            state = .playing
        case .fail(let failure):
            state = .failed(failure)
            throw failure
        case .hang:
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { c.resume(throwing: CancellationError()) } else { hanging = c }
                }
            } onCancel: {
                Task { @MainActor in self.cancelHang() }
            }
        }
    }

    func play() { state = .playing }
    func pause() {
        pauseCount += 1
        if state == .playing { state = .paused }
    }
    func seek(to seconds: Double) async { currentTime = seconds }
    func select(audioID: String?) {}
    func select(subtitleID: String?) {}

    func close() {
        cancelHang()
        state = .idle
    }

    func closeAndWait() async {
        closeAndWaitCount += 1
        close()
        if holdClose {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in closeGate = c }
        }
        await Task.yield()
        closeFinished = true
        log.events.append("closed")
    }

    /// Släpper en `closeAndWait()` som väntar (`holdClose`).
    func finishClose() {
        closeGate?.resume()
        closeGate = nil
    }

    func emit(_ newState: PlaybackState) { state = newState }

    private func cancelHang() {
        hanging?.resume(throwing: CancellationError())
        hanging = nil
    }
}

@MainActor
private final class PreviewEventLog {
    var events: [String] = []
}

/// Räknande omslutning runt en riktig `StreamConnectionBroker`: vilka leaser förhandsvisningen fått och hur många
/// gånger var och en släppts. Med grinden stängd väntar `acquirePreview` tills testet öppnar den (sen tilldelning).
private actor CountingBroker: PreviewConnections {
    let inner = StreamConnectionBroker()
    private(set) var acquireCalls = 0
    private(set) var acquired: [UUID] = []
    private(set) var releaseCounts: [UUID: Int] = [:]
    private var gated = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    var waitingAtGate: Int { gateWaiters.count }

    func setGated(_ value: Bool) { gated = value }

    func openGate() {
        gated = false
        let waiters = gateWaiters
        gateWaiters = []
        for w in waiters { w.resume() }
    }

    func acquirePreview(playlistID: UUID, onRevoke: @escaping @Sendable () async -> Void) async -> StreamLease? {
        acquireCalls += 1
        if gated {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in gateWaiters.append(c) }
        }
        // Fristående task: en sen tilldelning ska ske även om anroparen hunnit avbrytas (värsta fallet för kontrollern).
        let inner = inner
        let lease = await Task.detached { await inner.acquire(.preview, playlistID: playlistID, onRevoke: onRevoke) }.value
        if let lease { acquired.append(lease.id) }
        return lease
    }

    func release(_ lease: StreamLease) async {
        releaseCounts[lease.id, default: 0] += 1
        await inner.release(lease)
    }

    /// Varje beviljad lease har släppts exakt en gång (och inget annat har släppts).
    var eachReleasedExactlyOnce: Bool {
        Set(releaseCounts.keys) == Set(acquired) && releaseCounts.values.allSatisfy { $0 == 1 }
    }

    func releaseCount(_ id: UUID) -> Int { releaseCounts[id] ?? 0 }
}

/// Kontrollern med injicerade beroenden: en riktig `StreamConnectionBroker` (via `CountingBroker`), testmotorer och
/// testklocka.
@MainActor
private final class Harness {
    let connections = CountingBroker()
    var broker: StreamConnectionBroker { connections.inner }
    let playlistID = UUID()
    let sleeper = ManualSleeper()
    let log = PreviewEventLog()
    var engines: [PreviewTestEngine] = []
    var mode: PreviewTestEngine.Mode = .succeed
    var holdClose = false
    var settings = PlaybackSettings(previewSoundEnabled: false)
    var kidsAllowed = true
    var source: PreviewSource? = PreviewSource(url: URL(string: "http://example.invalid/movie/u/p/1.mp4")!,
                                               containerExtension: "mp4", durationHint: 6000)
    private(set) var resolveCount = 0
    private(set) var kidsChecks = 0
    /// Med satt grind väntar `resolve` respektive `kidsAllowed` tills testet öppnar den.
    var resolveGated = false
    var kidsGated = false
    private var resolveWaiter: CheckedContinuation<Void, Never>?
    private var kidsWaiter: CheckedContinuation<Void, Never>?
    var waitingInResolve: Bool { resolveWaiter != nil }
    var waitingInKids: Bool { kidsWaiter != nil }

    lazy var controller: PreviewController = makeController()

    func openResolve() {
        resolveWaiter?.resume()
        resolveWaiter = nil
    }

    func openKids() {
        kidsWaiter?.resume()
        kidsWaiter = nil
    }

    /// En ny kontroller med samma beroenden (för tester som släpper kontrollern själva).
    func makeController() -> PreviewController {
        let connections = connections
        let sleeper = sleeper
        return PreviewController(dependencies: PreviewController.Dependencies(
            broker: connections,
            makeEngine: { [self] in
                let engine = PreviewTestEngine(mode: mode, holdClose: holdClose, log: log)
                engines.append(engine)
                return engine
            },
            setMuted: { engine, muted in (engine as? PreviewTestEngine)?.muted = muted },
            resolve: { [self] _, _ in
                resolveCount += 1
                if resolveGated {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in resolveWaiter = c }
                }
                return source
            },
            settings: { [self] in settings },
            kidsAllowed: { [self] _, _ in
                kidsChecks += 1
                if kidsGated {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in kidsWaiter = c }
                }
                return kidsAllowed
            },
            sleep: { try await sleeper.sleep($0) }))
    }

    /// Flyttar fokus och väntar tills starten börjat vänta på stillastående (så att testklockan räknas från den).
    func focus(_ item: LibraryItem?, on target: PreviewController? = nil) async {
        let before = sleeper.requested.count
        (target ?? controller).focusChanged(to: item, playlistID: playlistID)
        guard item != nil, settings.previewsEnabled else { return }
        _ = await eventually { sleeper.requested.count > before }
    }

    /// Flyttar fokus och låter titeln bli stillastående (1,5 s).
    func focusAndSettle(_ item: LibraryItem, on target: PreviewController? = nil) async {
        await focus(item, on: target)
        sleeper.advance(by: .milliseconds(1500))
    }

    func eachReleasedExactlyOnce() async -> Bool {
        await connections.eachReleasedExactlyOnce
    }

    func activeLeases() async -> Int {
        await broker.activeCount(playlistID: playlistID)
    }

    func playingEngine() -> PreviewTestEngine? {
        if case .playing(let engine) = controller.state { return engine as? PreviewTestEngine }
        return nil
    }
}

private func movie(_ id: String) -> LibraryItem {
    LibraryItem(kind: .movie, providerID: id, title: "Film \(id)", year: 2020, posterURL: nil)
}

/// Väntar (riktig tid, högst `timeout`) tills villkoret är sant. Används när tasks ska hinna köra klart efter att
/// testklockan flyttats.
@MainActor
private func eventually(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + timeout
    while clock.now < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Låter väntande tasks köra en stund (för villkor som ska förbli falska).
@MainActor
private func drain() async {
    for _ in 0..<20 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

// MARK: - Tester

@MainActor
struct PreviewControllerTests {
    @Test func rapidFocusChangesLeaveNoActiveLeases() async {
        let h = Harness()
        // En titel blir stillastående och spelar; sedan 20 fokusbyten på 1 s (50 ms isär) där ingen titel hinner
        // bli stillastående.
        await h.focusAndSettle(movie("start"))
        #expect(await eventually { h.playingEngine() != nil })
        #expect(await h.activeLeases() == 1)
        for i in 0..<20 {
            await h.focus(movie("\(i)"))
            h.sleeper.advance(by: .milliseconds(50))
        }
        await drain()
        #expect(h.engines.count == 1)
        #expect(h.engines.first?.closeFinished == true)
        #expect(h.resolveCount == 1)
        #expect(await h.activeLeases() == 0)

        // Den sista titeln blir stillastående och startar; stop stänger den och släpper leasen.
        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.playingEngine() != nil })
        #expect(h.engines.count == 2)
        #expect(await h.activeLeases() == 1)
        await h.controller.stop()
        #expect(h.controller.state == .idle)
        #expect(h.engines.allSatisfy { $0.closeFinished })
        #expect(await h.activeLeases() == 0)
        #expect(await h.connections.acquired.count == 2)
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func rapidFocusChangesDuringLoadReleaseEveryLease() async {
        let h = Harness()
        h.mode = .hang
        // Varje titel hinner bli stillastående och börja ladda innan fokus flyttas.
        for i in 0..<5 {
            await h.focusAndSettle(movie("\(i)"))
            #expect(await eventually { h.engines.count == i + 1 && h.engines[i].loadCount == 1 })
        }
        await h.controller.stop()
        #expect(h.engines.allSatisfy { $0.closeFinished })
        #expect(await h.activeLeases() == 0)
        #expect(await h.connections.acquired.count == 5)
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func previewStartsOnlyAfterSettle() async {
        let h = Harness()
        h.controller.focusChanged(to: movie("1"), playlistID: h.playlistID)
        #expect(h.controller.state == .idle)
        #expect(await eventually { h.sleeper.requested == [.milliseconds(1500)] })
        h.sleeper.advance(by: .milliseconds(1499))
        await drain()
        #expect(h.engines.isEmpty)
        #expect(h.kidsChecks == 0)
        #expect(await h.activeLeases() == 0)

        h.sleeper.advance(by: .milliseconds(1))
        #expect(await eventually { h.playingEngine() != nil })
        let engine = h.engines.first
        #expect(h.engines.count == 1)
        #expect(engine?.loadedStartAt == PreviewPlan.startSeconds(duration: 6000))
        #expect(engine?.muted == true)
        #expect(await h.activeLeases() == 1)
        await h.controller.stop()
        #expect(await h.activeLeases() == 0)
        #expect(await h.connections.acquired.count == 1)
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func soundFollowsProfileSetting() async {
        let h = Harness()
        h.settings = PlaybackSettings(previewSoundEnabled: true)
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.playingEngine() != nil })
        let engine = h.engines.first
        #expect(engine?.muted == false)
        h.controller.setSoundEnabled(false)
        #expect(engine?.muted == true)
        h.controller.setSoundEnabled(true)
        #expect(engine?.muted == false)

        // Fokusbyte: ljudet av och pausat direkt (synkront), innan stängningen är klar.
        h.controller.focusChanged(to: movie("2"), playlistID: h.playlistID)
        #expect(engine?.muted == true)
        #expect((engine?.pauseCount ?? 0) >= 1)
        #expect(h.controller.state == .idle)
        await h.controller.stop()
        #expect(await h.activeLeases() == 0)
    }

    @Test func playbackActiveOnOneConnectionAccountFallsBackToArtwork() async {
        let h = Harness()
        await h.broker.setLimit(1, playlistID: h.playlistID)
        let revoked = RevokeFlag()
        let playback = await h.broker.acquire(.playback, playlistID: h.playlistID) { await revoked.set() }
        #expect(playback != nil)

        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.controller.state == .artwork(.connectionBusy) })
        #expect(h.engines.isEmpty)
        #expect(await revoked.value == false)
        #expect(await h.activeLeases() == 1)
        await h.controller.stop()
        #expect(await h.activeLeases() == 1)
        if let playback { await h.broker.release(playback) }
    }

    @Test func playbackRevokesPreviewWhichFallsBackToArtwork() async {
        let h = Harness()
        await h.broker.setLimit(1, playlistID: h.playlistID)
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.playingEngine() != nil })
        let engine = h.engines.first

        // Uppspelning tar anslutningen: förhandsvisningen stängs innan uppspelningen får platsen.
        let playback = await h.broker.acquire(.playback, playlistID: h.playlistID) {}
        #expect(playback != nil)
        #expect(engine?.closeFinished == true)
        #expect(h.controller.state == .artwork(.connectionBusy))
        #expect(await h.activeLeases() == 1)
        await h.controller.stop()
        #expect(await h.activeLeases() == 1)
        if let playback { await h.broker.release(playback) }
        #expect(await h.activeLeases() == 0)
    }

    @Test func startTimeoutAfterThreeSecondsFallsBackAndReleasesLease() async {
        let h = Harness()
        h.mode = .hang
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.engines.first?.loadCount == 1 })
        #expect(h.controller.state == .starting)
        #expect(await h.activeLeases() == 1)

        h.sleeper.advance(by: .milliseconds(2999))
        await drain()
        #expect(h.controller.state == .starting)

        h.sleeper.advance(by: .milliseconds(1))
        #expect(await eventually { h.controller.state == .artwork(nil) })
        await h.controller.closeTask?.value
        #expect(h.engines.first?.closeFinished == true)
        #expect(await h.activeLeases() == 0)
        #expect(h.sleeper.requested.contains(.seconds(3)))
        #expect(await h.connections.acquired.count == 1)
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func droppingControllerWithoutStopReleasesLease() async {
        let h = Harness()
        var c: PreviewController? = h.makeController()
        await h.focusAndSettle(movie("1"), on: c)
        #expect(await eventually { h.engines.first?.state == .playing })
        #expect(await h.activeLeases() == 1)
        c = nil
        #expect(await eventually { await h.activeLeases() == 0 })
        #expect(await eventually { h.engines.first?.closeFinished == true })
        await drain()
        #expect(h.engines.count == 1)
        #expect(h.engines.allSatisfy { $0.state != .playing })
        #expect(await h.connections.acquired.count == 1)
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func droppingControllerDuringLoadReleasesLease() async {
        let h = Harness()
        h.mode = .hang
        var c: PreviewController? = h.makeController()
        await h.focusAndSettle(movie("1"), on: c)
        #expect(await eventually { h.engines.first?.loadCount == 1 })
        c = nil
        #expect(await eventually { await h.activeLeases() == 0 })
        #expect(await eventually { h.engines.first?.closeFinished == true })
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func droppingControllerWhileAcquireIsPendingStartsNothingAndReleasesLateLease() async {
        let h = Harness()
        await h.connections.setGated(true)
        var c: PreviewController? = h.makeController()
        await h.focusAndSettle(movie("1"), on: c)
        #expect(await eventually { await h.connections.waitingAtGate == 1 })
        c = nil
        await h.connections.openGate()
        #expect(await eventually { await h.connections.acquired.count == 1 })
        #expect(await eventually { await h.activeLeases() == 0 })
        await drain()
        #expect(h.engines.isEmpty)
        #expect(await h.activeLeases() == 0)
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func lateLeaseAfterFocusChangeIsReleasedAndNeverPlays() async {
        let h = Harness()
        await h.connections.setGated(true)
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { await h.connections.waitingAtGate == 1 })
        h.controller.focusChanged(to: nil, playlistID: h.playlistID)
        await h.connections.openGate()
        #expect(await eventually { await h.connections.acquired.count == 1 })
        #expect(await eventually { await h.activeLeases() == 0 })
        await h.controller.stop()
        #expect(h.engines.isEmpty)
        #expect(!h.controller.isPlaying)
        #expect(h.controller.state == .idle)
        #expect(await h.activeLeases() == 0)
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func focusChangeDuringGatedResolveNeverAcquires() async {
        let h = Harness()
        h.resolveGated = true
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.waitingInResolve })
        #expect(h.controller.state == .starting)
        h.controller.focusChanged(to: nil, playlistID: h.playlistID)
        h.openResolve()
        await h.controller.stop()
        #expect(h.engines.isEmpty)
        #expect(await h.connections.acquireCalls == 0)
        #expect(h.controller.state == .idle)
        #expect(await h.activeLeases() == 0)
    }

    @Test func focusChangeDuringGatedKidsCheckNeverStartsOrAcquires() async {
        let h = Harness()
        h.kidsGated = true
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.waitingInKids })
        // .starting sätts först när barnfiltret godkänt titeln.
        #expect(h.controller.state == .idle)
        h.controller.focusChanged(to: nil, playlistID: h.playlistID)
        h.openKids()
        await h.controller.stop()
        #expect(h.resolveCount == 0)
        #expect(h.engines.isEmpty)
        #expect(await h.connections.acquireCalls == 0)
        #expect(h.controller.state == .idle)
    }

    @Test func revokeDuringLoadClosesEngineAndFallsBack() async {
        let h = Harness()
        h.mode = .hang
        await h.broker.setLimit(1, playlistID: h.playlistID)
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.engines.first?.loadCount == 1 })
        let playback = await h.broker.acquire(.playback, playlistID: h.playlistID) {}
        #expect(playback != nil)
        #expect(h.engines.first?.closeFinished == true)
        #expect(h.controller.state == .artwork(.connectionBusy))
        #expect(await h.activeLeases() == 1)
        await h.controller.stop()
        #expect(await h.connections.releaseCounts.isEmpty)
        if let playback { await h.broker.release(playback) }
        #expect(await h.activeLeases() == 0)
    }

    @Test func leaseReleasedOnlyAfterEngineClosed() async {
        let h = Harness()
        h.holdClose = true
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.playingEngine() != nil })
        let engine = h.engines.first

        h.controller.focusChanged(to: nil, playlistID: h.playlistID)
        #expect(h.controller.state == .idle)
        #expect(await eventually { engine?.isWaitingInClose == true })
        await drain()
        // Motorn har inte stängt klart: leasen ligger kvar.
        #expect(await h.activeLeases() == 1)

        engine?.finishClose()
        await h.controller.closeTask?.value
        #expect(engine?.closeFinished == true)
        #expect(await h.activeLeases() == 0)
    }

    @Test func stopNowStopsSynchronouslyAndLaterFocusSurvivesIt() async {
        let h = Harness()
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.playingEngine() != nil })
        let waiter = h.controller.stopNow()
        #expect(h.controller.state == .idle)   // stoppet skedde i anropet, inte i en försenad task
        // Snabb omfokusering innan någon hunnit vänta in stoppet: den nya starten får inte avbrytas av det.
        await h.focusAndSettle(movie("2"))
        await waiter.value
        #expect(await eventually { h.engines.count == 2 && h.playingEngine() != nil })
        #expect(h.engines.first?.closeFinished == true)
        #expect(await h.activeLeases() == 1)
        await h.controller.stop()
        #expect(await h.activeLeases() == 0)
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func stopDuringLoadClosesEngineAndReleasesLease() async {
        let h = Harness()
        h.mode = .hang
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.engines.first?.loadCount == 1 })
        #expect(await h.activeLeases() == 1)
        await h.controller.stop()
        #expect(h.controller.state == .idle)
        #expect(h.engines.first?.closeFinished == true)
        #expect(await h.activeLeases() == 0)
    }

    @Test func loadFailureFallsBackAndReleasesLease() async {
        let h = Harness()
        h.mode = .fail(.network)
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.controller.state == .artwork(nil) })
        await h.controller.closeTask?.value
        #expect(h.engines.first?.closeFinished == true)
        #expect(await h.activeLeases() == 0)
    }

    @Test func unsupportedContainerNeverAcquires() async {
        let h = Harness()
        h.source = PreviewSource(url: URL(string: "http://example.invalid/movie/u/p/1.mkv")!,
                                 containerExtension: "mkv", durationHint: nil)
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.controller.state == .artwork(.unsupportedContainer) })
        #expect(h.engines.isEmpty)
        #expect(await h.activeLeases() == 0)
    }

    @Test func kidsDeniedTitleNeverRequestsStream() async {
        let h = Harness()
        h.kidsAllowed = false
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.controller.state == .artwork(.kidsDenied) })
        #expect(h.kidsChecks == 1)
        #expect(h.resolveCount == 0)
        #expect(h.engines.isEmpty)
        #expect(await h.activeLeases() == 0)
    }

    @Test func previewsDisabledNeverAcquires() async {
        let h = Harness()
        h.settings = PlaybackSettings(previewsEnabled: false)
        h.controller.focusChanged(to: movie("1"), playlistID: h.playlistID)
        #expect(h.controller.state == .artwork(.disabled))
        h.sleeper.advance(by: .milliseconds(1500))
        await drain()
        #expect(h.controller.state == .artwork(.disabled))
        #expect(h.kidsChecks == 0)
        #expect(h.resolveCount == 0)
        #expect(h.engines.isEmpty)
        #expect(await h.activeLeases() == 0)
    }

    @Test func refocusingSameTitleKeepsPreview() async {
        let h = Harness()
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.playingEngine() != nil })
        h.controller.focusChanged(to: movie("1"), playlistID: h.playlistID)
        let same = h.playingEngine() === h.engines.first
        #expect(same)
        #expect(h.engines.count == 1)
        await h.controller.stop()
        #expect(await h.activeLeases() == 0)
    }

    /// Hem startar förhandsvisningen och detaljsidan tar över kontrollern: samma titel är en no-op, alltså samma
    /// motor, ingen ny anslutning och inget stopp-och-omstart.
    @Test func detailPageClaimingSameTitleWhilePlayingDoesNotRestart() async {
        let h = Harness()
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.playingEngine() != nil })
        let engine = h.playingEngine()
        h.controller.focusChanged(to: movie("1"), playlistID: h.playlistID)
        let same = h.playingEngine() === engine
        #expect(same)
        #expect(h.engines.count == 1)
        #expect(await h.activeLeases() == 1)
        await h.controller.stop()
        #expect(await h.activeLeases() == 0)
    }

    /// En annan titel ersätter ägarens förhandsvisning direkt (en ägare åt gången); den förra spelar inte vidare.
    @Test func claimingAnotherTitleReplacesTheOwnersPreviewImmediately() async {
        let h = Harness()
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.playingEngine() != nil })
        h.controller.focusChanged(to: movie("2"), playlistID: h.playlistID)
        #expect(h.playingEngine() == nil)
        // Tystas helt (personlistan visas): inget startar.
        h.controller.focusChanged(to: nil, playlistID: h.playlistID)
        #expect(h.playingEngine() == nil)
        await h.controller.stop()
        #expect(await h.activeLeases() == 0)
    }
}

private actor RevokeFlag {
    private(set) var value = false
    func set() { value = true }
}

// MARK: - Strömmen för förhandsvisningen (AppModel)

@MainActor
private func previewModel() async throws -> (AppModel, UUID) {
    let m = AppModel(store: LibraryStore(db: try .inMemory()), credentials: InMemoryCredentialStore(),
                     http: StubHTTPClient(fixtures: standardFixtures), defaults: freshDefaults())
    await m.addPlaylist(name: "Min", secret: xtreamSecret)
    let id = try #require(m.playlists.first?.id)
    m.enter(playlistID: id)
    try #require(m.activeProfile?.profile.playlistID == id)
    return (m, id)
}

@MainActor
struct PreviewSourceTests {
    @Test func seriesPreviewUsesFirstEpisodeOfLowestSeason() async throws {
        let (m, id) = try await previewModel()
        let series = LibraryItem(kind: .series, providerID: "5", title: "Fake Series", year: nil, posterURL: nil)
        let source = try #require(await m.previewRequest(for: series, playlistID: id))
        // S1E1 är avsnitt 501 (mkv); förhandsvisningen faller därför tillbaka till artwork i kontrollern.
        #expect(source.url.lastPathComponent == "501.mkv")
        #expect(source.containerExtension == "mkv")
    }

    @Test func moviePreviewUsesMovieStreamAndRuntime() async throws {
        let (m, id) = try await previewModel()
        try m.metadataStore.saveMatch(playlistID: id, kind: .movie, providerID: "103", tmdbID: 999, confidence: 1,
                                      now: Date())
        try m.metadataStore.saveMetadata(TitleMetadata(tmdbID: 999, kind: .movie, title: "Film", runtimeMinutes: 100,
                                                       language: "sv-SE"), now: Date())
        let item = LibraryItem(kind: .movie, providerID: "103", title: "Film", year: nil, posterURL: nil)
        let source = try #require(await m.previewRequest(for: item, playlistID: id))
        #expect(source.url.lastPathComponent == "103.mp4")
        #expect(source.containerExtension == "mp4")
        #expect(source.durationHint == 6000)
    }

    @Test func kidsProfileGetsNoStreamForUnratedTitle() async throws {
        let (m, id) = try await previewModel()
        let kid = try m.addProfile(playlistID: id, name: "Barn", avatar: "pawprint.fill", isKids: true)
        try await m.select(profile: kid, pin: nil)
        try #require(m.activeProfile?.profile.isKids == true)
        // 103 saknar åldersgräns: stängt som standard.
        let item = LibraryItem(kind: .movie, providerID: "103", title: "Film", year: nil, posterURL: nil)
        #expect(await m.previewRequest(for: item, playlistID: id) == nil)
        let live = LibraryItem(kind: .live, providerID: "1", title: "Kanal", year: nil, posterURL: nil)
        #expect(await m.previewRequest(for: live, playlistID: id) == nil)
    }
}
