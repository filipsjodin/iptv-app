import Core
import Foundation
import Playback
import PlaybackCore
import SwiftUI
import Testing
@testable import IPTVApp

/// Liten lokal motor. `PlaybackTestSupport` länkas inte in i testbundeln: Playback och PlaybackCore finns redan i
/// värdappen, och en extra kopia av typerna i bundeln kan få casts i appen att misslyckas (lärdom från fas 1).
@MainActor
final class TestEngine: PlayerEngine {
    let kind: EngineKind
    private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var currentTime: Double = 0
    private(set) var duration: Double?
    let audioTracks: [MediaTrack] = []
    let subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudioID: String?
    private(set) var selectedSubtitleID: String?
    let videoInfo: VideoInfo
    var onStateChange: ((PlaybackState) -> Void)?
    private(set) var loadCount = 0
    /// Delad logg över stängningar och laddningar (för ordningstester).
    var log: EventLog?
    /// Simulerar en motor som tar tid på sig att släppa anslutningen.
    var closeDelay: Duration?

    init(kind: EngineKind, info: VideoInfo = .unknown) {
        self.kind = kind
        self.videoInfo = info
    }

    func load(url: URL, startAt: Double?) async throws {
        log?.events.append("load")
        loadCount += 1
        duration = 1000
        currentTime = startAt ?? 0
        state = .playing
    }
    func play() { state = .playing }
    func pause() { state = .paused }
    func seek(to seconds: Double) async { currentTime = seconds }
    func select(audioID: String?) { selectedAudioID = audioID }
    func select(subtitleID: String?) { selectedSubtitleID = subtitleID }
    func close() { state = .idle }
    func closeAndWait() async {
        close()
        if let closeDelay { try? await Task.sleep(for: closeDelay) }
        await Task.yield()
        log?.events.append("closedAndWaited")
    }
    /// Simulerar att motorn själv byter state (t.ex. fel mitt i strömmen).
    func emit(_ newState: PlaybackState) { state = newState }
}

@MainActor
final class EventLog {
    var events: [String] = []
}

/// Räknar steg i nedräkningen och kan köra en åtgärd vid ett visst steg.
@MainActor
private final class StepCounter {
    var steps = 0
    var onStep: ((Int) -> Void)?

    func step() async {
        steps += 1
        onStep?(steps)
        await Task.yield()
    }
}

private let secret = PlaylistSecret.xtream(server: URL(string: "http://h:1")!, username: "u", password: "p")

private func episodeRequest(_ id: String) -> PlaybackRequest {
    PlaybackRequest(key: ProgressKey(playlistID: UUID(), kind: .series, providerID: id, seriesProviderID: "s1"),
                    title: id, locator: .xtream(kind: .series, streamID: id, container: "mp4"),
                    container: "mp4", isLive: false)
}

@MainActor
func makeSession(_ request: PlaybackRequest, kind: EngineKind = .avPlayer,
                 info: VideoInfo = .unknown, log: EventLog? = nil,
                 closeDelay: Duration? = nil) -> PlaybackSession {
    let pref: EnginePreference = kind == .vlc ? .vlc : .avPlayer
    return PlaybackSession(request: request, secret: secret, settings: PlaybackSettings(engine: pref),
                           userState: InMemoryUserStateStore(),
                           makeEngine: { k in
                               let e = TestEngine(kind: k, info: info)
                               e.log = log
                               e.closeDelay = closeDelay
                               return e
                           },
                           audioSession: AudioSessionControl(activate: {}, deactivate: {}))
}

@MainActor
struct PlayerScreenModelTests {
    @Test func countdownStartsNextEpisodeAtZero() async {
        let first = makeSession(episodeRequest("e1"))
        await first.start()
        var provided: [String] = []
        let counter = StepCounter()
        let model = PlayerScreenModel(
            session: first,
            nextEpisodeProvider: {
                provided.append("e2")
                return episodeRequest("e2")
            },
            makeSession: { makeSession($0) },
            stepper: { await counter.step() })

        model.startNextEpisodeCountdown()
        #expect(model.countdown == PlayerScreenModel.countdownSeconds)
        let task = model.countdownTask
        await task?.value

        #expect(counter.steps == 10)
        #expect(provided == ["e2"])
        #expect(model.session !== first)
        #expect(model.session.engine != nil)
        #expect((model.session.engine as? TestEngine)?.loadCount == 1)
        #expect(first.engine == nil)
        #expect(model.countdown == nil)
    }

    @Test func cancelStopsCountdown() async {
        let first = makeSession(episodeRequest("e1"))
        await first.start()
        var providerCalls = 0
        let counter = StepCounter()
        let model = PlayerScreenModel(
            session: first,
            nextEpisodeProvider: {
                providerCalls += 1
                return episodeRequest("e2")
            },
            makeSession: { makeSession($0) },
            stepper: { await counter.step() })
        counter.onStep = { step in if step == 3 { model.cancelCountdown() } }

        model.startNextEpisodeCountdown()
        let task = model.countdownTask
        await task?.value

        #expect(counter.steps == 3)
        #expect(providerCalls == 0)
        #expect(model.session === first)
        #expect(model.countdown == nil)
        #expect(first.engine != nil)

        // Avbruten nedräkning startar inte om för samma avsnitt.
        model.startNextEpisodeCountdown()
        #expect(model.countdown == nil)
    }

    @Test func infoSummaryIncludesEngine() async {
        let info = VideoInfo(width: 3840, height: 2160, dynamicRange: .dolbyVision, videoCodec: "dvh1",
                             audioDescription: nil, bitrate: nil, frameRate: nil)
        let session = makeSession(episodeRequest("e1"), kind: .vlc, info: info)
        await session.start()
        let model = PlayerScreenModel(session: session, nextEpisodeProvider: nil, makeSession: { makeSession($0) })
        #expect(model.infoSummary == "2160p · Dolby Vision · VLC")
    }

    @Test func infoSummaryWithoutVideoInfoIsEngineName() async {
        let session = makeSession(episodeRequest("e1"), kind: .avPlayer)
        await session.start()
        let model = PlayerScreenModel(session: session, nextEpisodeProvider: nil, makeSession: { makeSession($0) })
        #expect(model.infoSummary == "Apple")
    }

    @Test func countdownPausesWithPlaybackAndResumes() async throws {
        let session = makeSession(episodeRequest("e1"))
        await session.start()
        let model = PlayerScreenModel(session: session, nextEpisodeProvider: { episodeRequest("e2") },
                                      makeSession: { makeSession($0) },
                                      stepper: { try? await Task.sleep(for: .seconds(60)) })
        let engine = try #require(session.engine as? TestEngine)
        engine.currentTime = 980   // 20 s kvar av 1000: inom erbjudandefönstret

        model.tick()
        #expect(model.countdown == PlayerScreenModel.countdownSeconds)
        #expect(model.countdownTask != nil)

        engine.pause()
        model.tick()
        #expect(model.countdownTask == nil)
        #expect(model.countdownPaused)
        #expect(model.countdown == PlayerScreenModel.countdownSeconds)

        engine.play()
        model.tick()
        #expect(model.countdownTask != nil)
        #expect(!model.countdownPaused)

        // Spolat tillbaka ur fönstret: nedräkningen släpps och erbjuds igen nära slutet.
        engine.currentTime = 100
        model.tick()
        #expect(model.countdown == nil)
        #expect(model.countdownTask == nil)
        engine.currentTime = 985
        model.tick()
        #expect(model.countdownTask != nil)

        // Fel mitt i strömmen fryser nedräkningen.
        engine.emit(.failed(.network))
        model.tick()
        #expect(model.countdownTask == nil)
        #expect(model.countdownPaused)
        model.stop()
    }

    @Test func endedDuringCountdownAdvancesImmediately() async throws {
        let first = makeSession(episodeRequest("e1"))
        await first.start()
        var providerCalls = 0
        let model = PlayerScreenModel(session: first,
                                      nextEpisodeProvider: {
                                          providerCalls += 1
                                          return episodeRequest("e2")
                                      },
                                      makeSession: { makeSession($0) },
                                      stepper: { try? await Task.sleep(for: .seconds(60)) })
        let engine = try #require(first.engine as? TestEngine)
        engine.currentTime = 980
        model.tick()
        #expect(model.countdown == PlayerScreenModel.countdownSeconds)

        engine.emit(.ended)
        model.tick()
        #expect(model.countdown == nil)
        #expect(model.countdownTask == nil)
        let task = try #require(model.advanceTask)
        await task.value

        #expect(providerCalls == 1)
        #expect(model.session !== first)
        #expect(model.session.engine != nil)
        model.stop()
    }

    @Test func endedAfterCancelledCountdownDoesNotAdvance() async throws {
        let first = makeSession(episodeRequest("e1"))
        await first.start()
        var providerCalls = 0
        let model = PlayerScreenModel(session: first,
                                      nextEpisodeProvider: {
                                          providerCalls += 1
                                          return episodeRequest("e2")
                                      },
                                      makeSession: { makeSession($0) },
                                      stepper: { try? await Task.sleep(for: .seconds(60)) })
        let engine = try #require(first.engine as? TestEngine)
        engine.currentTime = 980
        model.tick()
        model.cancelCountdown()
        engine.emit(.ended)
        model.tick()
        #expect(model.countdownTask == nil)
        #expect(model.advanceTask == nil)
        #expect(providerCalls == 0)
        #expect(model.session === first)
        model.stop()
    }

    @Test func disappearDuringSystemFullScreenDoesNotStop() async {
        let session = makeSession(episodeRequest("e1"))
        await session.start()
        let model = PlayerScreenModel(session: session, nextEpisodeProvider: nil, makeSession: { makeSession($0) })
        model.systemFullScreenActive = true
        model.viewDisappeared()
        #expect(session.engine != nil)
        model.systemFullScreenActive = false
        model.viewDisappeared()
        #expect(session.engine == nil)
        #expect(session.state == .idle)
    }

    @Test func scenePolicyPerPlatformAndEngine() {
        typealias M = PlayerScreenModel
        // tvOS: alltid paus och sparning.
        for engine in [EngineKind.avPlayer, .vlc] {
            #expect(M.scenePolicy(phase: .inactive, engine: engine, pipActive: true, externalActive: true,
                                  isTV: true) == .pauseAndSave)
            #expect(M.scenePolicy(phase: .background, engine: engine, pipActive: false, externalActive: false,
                                  isTV: true) == .pauseAndSave)
            #expect(M.scenePolicy(phase: .active, engine: engine, pipActive: false, externalActive: false,
                                  isTV: true) == .none)
        }
        // iOS, inaktiv: bara spara.
        for engine in [EngineKind.avPlayer, .vlc] {
            #expect(M.scenePolicy(phase: .inactive, engine: engine, pipActive: false, externalActive: false,
                                  isTV: false) == .save)
        }
        // iOS, bakgrund, Apples spelare: paus bara utan bild-i-bild och AirPlay.
        #expect(M.scenePolicy(phase: .background, engine: .avPlayer, pipActive: false, externalActive: false,
                              isTV: false) == .pauseAndSave)
        #expect(M.scenePolicy(phase: .background, engine: .avPlayer, pipActive: true, externalActive: false,
                              isTV: false) == .save)
        #expect(M.scenePolicy(phase: .background, engine: .avPlayer, pipActive: false, externalActive: true,
                              isTV: false) == .save)
        // iOS, bakgrund, VLC: alltid paus.
        #expect(M.scenePolicy(phase: .background, engine: .vlc, pipActive: true, externalActive: true,
                              isTV: false) == .pauseAndSave)
        #expect(M.scenePolicy(phase: .active, engine: .vlc, pipActive: false, externalActive: false,
                              isTV: false) == .none)
    }

    @Test func errorKeysAreLocalized() throws {
        let keys = ["playback.error.unsupported", "playback.error.network", "playback.error.generic",
                    "playback.error.liveEnded"]
        for lang in ["sv", "en"] {
            let path = try #require(Bundle.main.path(forResource: lang, ofType: "lproj"), "saknar \(lang).lproj")
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "<missing>", table: "Localizable")
                #expect(value != "<missing>" && value != key, "\(key) saknas på \(lang)")
            }
        }
    }

    @Test func idleTimerOnlyForPlayingVLC() {
        typealias M = PlayerScreenModel
        #expect(M.shouldDisableIdleTimer(engine: .vlc, state: .playing, hasError: false, stopped: false))
        #expect(M.shouldDisableIdleTimer(engine: .vlc, state: .buffering, hasError: false, stopped: false))
        #expect(!M.shouldDisableIdleTimer(engine: .vlc, state: .paused, hasError: false, stopped: false))
        #expect(!M.shouldDisableIdleTimer(engine: .vlc, state: .ended, hasError: false, stopped: false))
        #expect(!M.shouldDisableIdleTimer(engine: .vlc, state: .loading, hasError: false, stopped: false))
        #expect(!M.shouldDisableIdleTimer(engine: .vlc, state: .playing, hasError: true, stopped: false))
        #expect(!M.shouldDisableIdleTimer(engine: .vlc, state: .playing, hasError: false, stopped: true))
        #expect(!M.shouldDisableIdleTimer(engine: .avPlayer, state: .playing, hasError: false, stopped: false))
        #expect(!M.shouldDisableIdleTimer(engine: nil, state: nil, hasError: false, stopped: false))
    }

    @Test func idleTimerFollowsVLCPlaybackAndStop() async throws {
        let session = makeSession(episodeRequest("e1"), kind: .vlc)
        await session.start()
        var applied: [Bool] = []
        let model = PlayerScreenModel(session: session, nextEpisodeProvider: nil, makeSession: { makeSession($0) },
                                      setIdleTimerDisabled: { applied.append($0) })
        model.tick()
        #expect(applied == [true])
        model.tick()
        #expect(applied == [true])
        let engine = try #require(session.engine as? TestEngine)
        engine.pause()
        model.applyIdleTimer()
        #expect(applied == [true, false])
        engine.play()
        model.tick()
        model.stop()
        #expect(applied == [true, false, true, false])
    }

    @Test func advanceWaitsForCloseBeforeNextLoad() async {
        let log = EventLog()
        let first = makeSession(episodeRequest("e1"), log: log)
        await first.start()
        let model = PlayerScreenModel(
            session: first,
            nextEpisodeProvider: { episodeRequest("e2") },
            makeSession: { makeSession($0, log: log) },
            stepper: {})
        model.startNextEpisodeCountdown()
        let task = model.countdownTask
        await task?.value
        #expect(log.events == ["load", "closedAndWaited", "load"])
        #expect(model.session !== first)
    }
}
