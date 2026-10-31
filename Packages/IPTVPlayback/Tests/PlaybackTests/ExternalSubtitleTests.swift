import Core
import Foundation
import Testing
import Playback
import PlaybackCore
import PlaybackTestSupport
import Subtitles

// MARK: - Hjälpare

private let playlistID = UUID()
private let srt = """
1
00:00:01,000 --> 00:00:03,000
Hej

2
00:00:05,000 --> 00:00:07,000
Världen

"""

private func writeSRT() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ext-sub-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("sub.srt")
    try Data(srt.utf8).write(to: url)
    return url
}

private func missingURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("saknas-\(UUID().uuidString).srt")
}

private func embedded(_ id: String, _ lang: String) -> MediaTrack {
    MediaTrack(id: id, kind: .subtitle, languageCode: lang, title: id, codec: nil, channelCount: nil,
               isAtmos: false, isDefault: false, isForced: false)
}

private func audioTrack(_ id: String, _ lang: String) -> MediaTrack {
    MediaTrack(id: id, kind: .audio, languageCode: lang, title: id, codec: nil, channelCount: 2,
               isAtmos: false, isDefault: true, isForced: false)
}

/// Fabrik där båda motorerna har ett engelskt ljudspår och ett inbyggt engelskt textspår "0".
@MainActor
private func factory() -> EngineFactory {
    let script = FakeEngine.Script.succeeding(duration: 1000, audio: [audioTrack("a0", "en")],
                                              subtitles: [embedded("0", "en")], info: .unknown)
    return EngineFactory([.avPlayer: script, .vlc: script])
}

@MainActor
private func session(_ f: EngineFactory, mode: SubtitleMode) -> PlaybackSession {
    let key = ProgressKey(playlistID: playlistID, kind: .movie, providerID: "42", seriesProviderID: nil)
    let req = PlaybackRequest(key: key, title: "Titel", locator: .xtream(kind: .movie, streamID: "42", container: "mp4"),
                              container: "mp4", isLive: false)
    let secret = PlaylistSecret.xtream(server: URL(string: "http://example.com:8080")!, username: "user", password: "pw")
    let settings = PlaybackSettings(tracks: TrackPreferences(audioLanguages: ["en"], subtitleMode: mode,
                                                             subtitleLanguages: ["sv"], preferSurround: false))
    return PlaybackSession(request: req, secret: secret, settings: settings, userState: InMemoryUserStateStore(),
                           makeEngine: { f.make($0) }, audioSession: AudioSessionControl(activate: {}, deactivate: {}))
}

private func sub(_ fileID: Int, _ url: URL, language: String? = "sv", title: String = "Film.2020.WEB") -> ExternalSubtitle {
    ExternalSubtitle(fileID: fileID, fileURL: url, language: language, title: title)
}

/// Texten för aktiv cue vid `time` enligt motorns överlagringsuppslag (nil: ingen provider eller ingen cue).
@MainActor
private func cueText(_ e: FakeEngine, at time: Double) -> String? {
    guard let provider = e.externalCueProvider else { return nil }
    return provider(time)?.text
}

/// Motor som bara uppfyller kraven och använder standardimplementationerna av de externa medlemmarna.
@MainActor
private final class BareEngine: PlayerEngine {
    let kind: EngineKind = .avPlayer
    var state: PlaybackState = .idle
    var currentTime: Double = 0
    var duration: Double?
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var selectedAudioID: String?
    var selectedSubtitleID: String?
    var videoInfo: VideoInfo = .unknown
    var onStateChange: ((PlaybackState) -> Void)?
    func load(url: URL, startAt: Double?) async throws {}
    func play() {}
    func pause() {}
    func seek(to seconds: Double) async {}
    func select(audioID: String?) {}
    func select(subtitleID: String?) {}
    func close() {}
}

// MARK: - Tester

@MainActor @Suite struct ExternalSubtitleTests {
    @Test func externalTrackAppearsInSubtitleTracksWithExtId() async throws {
        let f = factory()
        let s = session(f, mode: .off)
        await s.start()
        await s.attachExternalSubtitles([sub(7, try writeSRT())], offset: 0)
        let tracks = try #require(f.last(.avPlayer)).subtitleTracks
        let ext = try #require(tracks.first { $0.id == "ext:7" })
        #expect(ext.kind == .subtitle)
        #expect(ext.isExternal)
        #expect(!ext.isForced)
        #expect(ext.languageCode == "sv")
        #expect(ext.title == "Film.2020.WEB")
        #expect(tracks.contains { $0.id == "0" })
    }

    @Test func attachSelectsExternalWhenSelectorPrefersIt() async throws {
        let f = factory()
        let s = session(f, mode: .always)   // föredraget textspråk sv; bara den externa är svenska
        await s.start()
        await s.attachExternalSubtitles([sub(7, try writeSRT())], offset: 0)
        #expect(try #require(f.last(.avPlayer)).selectedSubtitleID == "ext:7")
    }

    @Test func selectingExternalEnablesCueProvider() async throws {
        let f = factory()
        let s = session(f, mode: .off)
        await s.start()
        await s.attachExternalSubtitles([sub(7, try writeSRT())], offset: 0)
        let e = try #require(f.last(.avPlayer))
        #expect(e.selectedSubtitleID == nil)
        #expect(e.externalCueProvider == nil)
        s.selectSubtitle("ext:7")
        #expect(e.externalCueProvider != nil)
        #expect(cueText(e, at: 1.5) == "Hej")
        #expect(cueText(e, at: 4) == nil)
        #expect(cueText(e, at: 6) == "Världen")
    }

    @Test func selectingEmbeddedDisablesExternal() async throws {
        let f = factory()
        let s = session(f, mode: .off)
        await s.start()
        await s.attachExternalSubtitles([sub(7, try writeSRT())], offset: 0)
        let e = try #require(f.last(.avPlayer))
        s.selectSubtitle("ext:7")
        #expect(e.externalCueProvider != nil)
        s.selectSubtitle("0")
        #expect(e.selectedSubtitleID == "0")
        #expect(e.externalCueProvider == nil)
        s.selectSubtitle("ext:7")
        s.selectSubtitle(nil)
        #expect(e.externalCueProvider == nil)
    }

    @Test func offsetShiftsCueLookup() async throws {
        let f = factory()
        let s = session(f, mode: .off)
        await s.start()
        await s.attachExternalSubtitles([sub(7, try writeSRT())], offset: 0)
        let e = try #require(f.last(.avPlayer))
        s.selectSubtitle("ext:7")
        #expect(e.externalCueProvider != nil)
        #expect(cueText(e, at: 0.95) == nil)

        // Uppslagstid = tid + förskjutning.
        s.setSubtitleOffset(0.1)
        #expect(cueText(e, at: 0.95) == "Hej")
        #expect(cueText(e, at: 3.05) == nil)

        s.setSubtitleOffset(-0.1)
        #expect(cueText(e, at: 3.05) == "Hej")
        #expect(e.externalCueProvider != nil)
        #expect(cueText(e, at: 0.95) == nil)
    }

    @Test func initialOffsetFromAttachIsApplied() async throws {
        let f = factory()
        let s = session(f, mode: .off)
        await s.start()
        await s.attachExternalSubtitles([sub(7, try writeSRT())], offset: 0.1)
        let e = try #require(f.last(.avPlayer))
        s.selectSubtitle("ext:7")
        #expect(e.subtitleOffset == 0.1)
        #expect(cueText(e, at: 0.95) == "Hej")
    }

    @Test func engineSwitchReattachesExternalAndKeepsSelection() async throws {
        let f = factory()
        let s = session(f, mode: .off)   // ingen automatisk textväljare: valet nedan är uttryckligt
        await s.start()
        await s.attachExternalSubtitles([sub(7, try writeSRT())], offset: 0.3)
        s.selectSubtitle("ext:7")
        #expect(s.engine?.kind == .avPlayer)

        await s.switchEngine(to: .vlc)
        let vlc = try #require(f.last(.vlc))
        #expect(s.engine === vlc)
        #expect(vlc.subtitleTracks.contains { $0.id == "ext:7" })
        #expect(vlc.selectedSubtitleID == "ext:7")
        #expect(vlc.subtitleOffset == 0.3)
        #expect(cueText(vlc, at: 0.8) == "Hej")   // 0.8 + 0.3 ligger i första cuen
    }

    @Test func engineSwitchKeepsEmbeddedSelectionWhenExternalNotSelected() async throws {
        let f = factory()
        let s = session(f, mode: .off)
        await s.start()
        await s.attachExternalSubtitles([sub(7, try writeSRT())], offset: 0)
        s.selectSubtitle("0")
        await s.switchEngine(to: .vlc)
        let vlc = try #require(f.last(.vlc))
        #expect(vlc.subtitleTracks.contains { $0.id == "ext:7" })
        #expect(vlc.selectedSubtitleID == "0")
        #expect(vlc.externalCueProvider == nil)
    }

    @Test func attachSkipsMissingFilesWithoutFailing() async throws {
        let f = factory()
        let s = session(f, mode: .off)
        await s.start()
        await s.attachExternalSubtitles([sub(1, missingURL()), sub(2, try writeSRT())], offset: 0)
        let e = try #require(f.last(.avPlayer))
        #expect(!e.subtitleTracks.contains { $0.id == "ext:1" })
        #expect(e.subtitleTracks.contains { $0.id == "ext:2" })
        #expect(e.addedExternalIDs == [2])
        #expect(s.state == .playing)
        #expect(s.errorMessageKey == nil)
    }

    @Test func unsupportedEngineThrowsUnsupported() async throws {
        let engine = BareEngine()
        do {
            try await engine.addExternalSubtitle(fileURL: try writeSRT(), language: "sv", title: "t", fileID: 1)
            Issue.record("förväntade ExternalSubtitleError.unsupported")
        } catch let error as ExternalSubtitleError {
            #expect(error == .unsupported)
        }
        #expect(engine.externalCueProvider == nil)
        engine.setSubtitleOffset(1)   // ska inte kasta eller krascha

        // En motor utan stöd får inte fälla sessionen.
        let f = factory()
        let s = session(f, mode: .off)
        await s.start()
        let unsupported = try #require(f.last(.avPlayer))
        unsupported.supportsExternalSubtitles = false
        await s.attachExternalSubtitles([sub(7, try writeSRT())], offset: 0)
        #expect(s.state == .playing)
        #expect(!unsupported.subtitleTracks.contains { $0.isExternal })
    }

    @Test func offsetClampedToLimits() async throws {
        let f = factory()
        let s = session(f, mode: .off)
        await s.start()
        let e = try #require(f.last(.avPlayer))
        s.setSubtitleOffset(1000)
        #expect(e.subtitleOffset == SubtitleTrack.maxOffset)
        s.setSubtitleOffset(-1000)
        #expect(e.subtitleOffset == -SubtitleTrack.maxOffset)
        s.setSubtitleOffset(0.26)
        #expect(e.subtitleOffset == 0.3)
        s.setSubtitleOffset(0.04)
        #expect(e.subtitleOffset == 0)
        s.setSubtitleOffset(.nan)
        #expect(e.subtitleOffset == 0)
        // Samma klampning för förskjutningen som skickas med vid attach.
        await s.attachExternalSubtitles([], offset: 9999)
        #expect(e.subtitleOffset == SubtitleTrack.maxOffset)
    }
}
