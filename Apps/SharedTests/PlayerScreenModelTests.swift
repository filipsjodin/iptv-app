import Core
import Foundation
import Playback
import PlaybackCore
import Testing
@testable import IPTVApp

/// Liten lokal motor. `PlaybackTestSupport` länkas inte in i testbundeln: Playback och PlaybackCore finns redan i
/// värdappen, och en extra kopia av typerna i bundeln kan få casts i appen att misslyckas (lärdom från fas 1).
@MainActor
private final class TestEngine: PlayerEngine {
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

    init(kind: EngineKind, info: VideoInfo = .unknown) {
        self.kind = kind
        self.videoInfo = info
    }

    func load(url: URL, startAt: Double?) async throws {
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
private func makeSession(_ request: PlaybackRequest, kind: EngineKind = .avPlayer,
                         info: VideoInfo = .unknown) -> PlaybackSession {
    let pref: EnginePreference = kind == .vlc ? .vlc : .avPlayer
    return PlaybackSession(request: request, secret: secret, settings: PlaybackSettings(engine: pref),
                           userState: InMemoryUserStateStore(),
                           makeEngine: { k in TestEngine(kind: k, info: info) })
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

    @Test func errorKeysAreLocalized() throws {
        let keys = ["playback.error.unsupported", "playback.error.network", "playback.error.generic"]
        for lang in ["sv", "en"] {
            let path = try #require(Bundle.main.path(forResource: lang, ofType: "lproj"), "saknar \(lang).lproj")
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "<missing>", table: "Localizable")
                #expect(value != "<missing>" && value != key, "\(key) saknas på \(lang)")
            }
        }
    }
}
