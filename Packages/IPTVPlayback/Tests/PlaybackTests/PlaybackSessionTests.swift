import Core
import Foundation
import Testing
import Playback
import PlaybackCore
import PlaybackTestSupport

// MARK: - Hjälpare

/// Skapar FakeEngine per motortyp enligt skript och minns de skapade motorerna.
@MainActor
final class EngineFactory {
    var scripts: [EngineKind: FakeEngine.Script]
    let recorder = EngineRecorder()
    private(set) var made: [FakeEngine] = []

    init(_ scripts: [EngineKind: FakeEngine.Script]) { self.scripts = scripts }

    func make(_ kind: EngineKind) -> any PlayerEngine {
        let e = FakeEngine(kind: kind, script: scripts[kind] ?? .succeeding(), recorder: recorder)
        made.append(e)
        return e
    }

    func last(_ kind: EngineKind) -> FakeEngine? { made.last { $0.kind == kind } }
}

/// Injicerbar klocka.
final class TestClock: @unchecked Sendable {
    // @unchecked Sendable: används bara från MainActor-tester.
    var date = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: Double) { date = date.addingTimeInterval(seconds) }
}

/// Lager som räknar sparningar.
final class CountingStore: UserStateStore, @unchecked Sendable {
    // @unchecked Sendable: `saves` skyddas av `lock`; resten delegeras till ett trådsäkert lager.
    private let inner = InMemoryUserStateStore()
    private let lock = NSLock()
    private var _saves = 0
    var saves: Int { lock.withLock { _saves } }

    func progress(for key: ProgressKey) -> WatchProgress? { inner.progress(for: key) }
    func save(_ progress: WatchProgress) { lock.withLock { _saves += 1 }; inner.save(progress) }
    func continueWatching(playlistID: UUID, limit: Int) -> [WatchProgress] {
        inner.continueWatching(playlistID: playlistID, limit: limit)
    }
    func lastWatchedEpisode(playlistID: UUID, seriesProviderID: String) -> WatchProgress? {
        inner.lastWatchedEpisode(playlistID: playlistID, seriesProviderID: seriesProviderID)
    }
    func remove(playlistID: UUID) { inner.remove(playlistID: playlistID) }
}

private let playlistID = UUID()
private let password = "S3cr3t-PW"
private let secret = PlaylistSecret.xtream(server: URL(string: "http://example.com:8080")!, username: "user", password: password)

private func key(_ kind: ContentKind) -> ProgressKey {
    ProgressKey(playlistID: playlistID, kind: kind, providerID: "42", seriesProviderID: kind == .series ? "7" : nil)
}

private func request(kind: ContentKind = .movie, container: String? = "mp4", startAt: Double? = nil) -> PlaybackRequest {
    let locatorKind: ContentKind = kind
    return PlaybackRequest(key: key(kind), title: "Titel",
                           locator: .xtream(kind: locatorKind, streamID: "42", container: container ?? "ts"),
                           container: container, isLive: kind == .live, startAt: startAt)
}

@MainActor
private func session(_ factory: EngineFactory,
                     request req: PlaybackRequest = request(),
                     secret sec: PlaylistSecret = secret,
                     settings: PlaybackSettings = PlaybackSettings(),
                     store: UserStateStore = CountingStore(),
                     clock: TestClock = TestClock()) -> PlaybackSession {
    PlaybackSession(request: req, secret: sec, settings: settings, userState: store,
                    makeEngine: { factory.make($0) }, now: { clock.date })
}

private func track(_ id: String, _ kind: TrackKind, _ lang: String?, channels: Int? = nil,
                   isDefault: Bool = false, isForced: Bool = false) -> MediaTrack {
    MediaTrack(id: id, kind: kind, languageCode: lang, title: id, codec: nil, channelCount: channels,
               isAtmos: false, isDefault: isDefault, isForced: isForced)
}

// MARK: - Tester

@MainActor @Suite struct PlaybackSessionTests {
    @Test func automaticFallsBackToVLCOnce() async {
        let f = EngineFactory([.avPlayer: .failing(.unsupportedFormat), .vlc: .succeeding()])
        let s = session(f)
        await s.start()
        #expect(f.recorder.kinds == [.avPlayer, .vlc])
        #expect(s.state == .playing)
        #expect(f.recorder.closeCount(.avPlayer) == 1)
        #expect(s.errorMessageKey == nil)
        #expect(s.engine?.kind == .vlc)
    }

    @Test func failingBothEnginesShowsFriendlyErrorOnce() async {
        let f = EngineFactory([.avPlayer: .failing(.network), .vlc: .failing(.network)])
        let s = session(f)
        await s.start()
        #expect(s.errorMessageKey == "playback.error.network")
        #expect(f.recorder.kinds.count == 2)
        #expect(s.state == .failed(.network))
    }

    @Test func errorKeyUsesLastEnginesFailure() async {
        let f = EngineFactory([.avPlayer: .failing(.network), .vlc: .failing(.unsupportedFormat)])
        let s = session(f)
        await s.start()
        #expect(s.errorMessageKey == "playback.error.unsupported")
    }

    @Test func timeoutAndUnknownMapToFriendlyKeys() async {
        let f1 = EngineFactory([.avPlayer: .failing(.timeout)])
        let s1 = session(f1, settings: PlaybackSettings(engine: .avPlayer))
        await s1.start()
        #expect(s1.errorMessageKey == "playback.error.network")

        let f2 = EngineFactory([.vlc: .failing(.unknown)])
        let s2 = session(f2, settings: PlaybackSettings(engine: .vlc))
        await s2.start()
        #expect(s2.errorMessageKey == "playback.error.generic")
    }

    @Test func explicitPreferenceNeverFallsBack() async {
        let f = EngineFactory([.avPlayer: .failing(.unsupportedFormat), .vlc: .succeeding()])
        let s = session(f, settings: PlaybackSettings(engine: .avPlayer))
        await s.start()
        #expect(f.recorder.kinds == [.avPlayer])
        #expect(s.errorMessageKey == "playback.error.unsupported")
        #expect(s.state == .failed(.unsupportedFormat))
    }

    @Test func previousEngineClosedBeforeNextOpens() async {
        // max_connections == 1: close(avPlayer) måste ske före load(vlc).
        let f = EngineFactory([.avPlayer: .failing(.network), .vlc: .succeeding()])
        let s = session(f)
        await s.start()
        #expect(f.recorder.events == [
            .made(.avPlayer), .loaded(.avPlayer, startAt: nil), .closed(.avPlayer),
            .made(.vlc), .loaded(.vlc, startAt: nil),
        ])
    }

    @Test func stopDuringStartDoesNotFallBack() async {
        let f = EngineFactory([.avPlayer: .hanging, .vlc: .succeeding()])
        let s = session(f)
        let task = Task { await s.start() }
        for _ in 0..<1000 where !f.recorder.events.contains(.loaded(.avPlayer, startAt: nil)) {
            await Task.yield()
        }
        #expect(f.recorder.events.contains(.loaded(.avPlayer, startAt: nil)))
        s.stop()
        await task.value
        #expect(f.recorder.kinds == [.avPlayer])
        #expect(s.state == .idle)
        #expect(s.errorMessageKey == nil)
        #expect(s.engine == nil)
    }

    @Test func cancellingHostTaskClosesEngine() async {
        let f = EngineFactory([.avPlayer: .hanging, .vlc: .succeeding()])
        let s = session(f)
        let task = Task { await s.start() }
        for _ in 0..<1000 where !f.recorder.events.contains(.loaded(.avPlayer, startAt: nil)) {
            await Task.yield()
        }
        task.cancel()
        await task.value
        #expect(f.recorder.kinds == [.avPlayer])
        #expect(f.recorder.closeCount(.avPlayer) == 1)
        #expect(s.state == .idle)
        #expect(s.errorMessageKey == nil)
        #expect(s.engine == nil)
    }

    @Test func midStreamFailureShowsErrorAndSaves() async {
        // Fel mitt i strömmen: ingen automatisk reserv (bara vid start), men felet visas och positionen sparas.
        let f = EngineFactory([.avPlayer: .succeeding(), .vlc: .succeeding()])
        let store = CountingStore()
        let s = session(f, store: store)
        await s.start()
        f.last(.avPlayer)?.currentTime = 300
        f.last(.avPlayer)?.emit(.failed(.network))
        #expect(s.state == .failed(.network))
        #expect(s.errorMessageKey == "playback.error.network")
        #expect(store.progress(for: key(.movie))?.position == 300)
        #expect(f.recorder.kinds == [.avPlayer])
    }

    @Test func endedSavesProgress() async {
        let f = EngineFactory([.avPlayer: .succeeding()])
        let store = CountingStore()
        let s = session(f, store: store)
        await s.start()
        f.last(.avPlayer)?.currentTime = 1000
        f.last(.avPlayer)?.emit(.ended)
        #expect(s.state == .ended)
        #expect(store.progress(for: key(.movie))?.watched == true)
    }

    @Test func unresolvableURLShowsGenericError() async {
        // Xtream-locator men m3u-hemlighet utan inloggning -> uppslagningen misslyckas.
        let f = EngineFactory([:])
        let m3u = PlaylistSecret.m3u(url: URL(string: "http://example.com/list.m3u")!, epgURL: nil)
        let s = session(f, secret: m3u)
        await s.start()
        #expect(s.errorMessageKey == "playback.error.generic")
        #expect(f.recorder.kinds.isEmpty)
    }

    @Test func switchPreservesPositionAndLanguages() async {
        let avAudio = [track("av-en", .audio, "en"), track("av-sv", .audio, "sv")]
        let avSubs = [track("av-sub-sv", .subtitle, "sv"), track("av-sub-en", .subtitle, "en")]
        let vlcAudio = [track("vlc-en", .audio, "eng"), track("vlc-sv", .audio, "swe")]
        let vlcSubs = [track("vlc-sub-sv", .subtitle, "swe"), track("vlc-sub-en", .subtitle, "eng")]
        let f = EngineFactory([
            .avPlayer: .succeeding(duration: 3000, audio: avAudio, subtitles: avSubs, info: .unknown),
            .vlc: .succeeding(duration: 3000, audio: vlcAudio, subtitles: vlcSubs, info: .unknown),
        ])
        let s = session(f)
        await s.start()
        s.selectAudio("av-sv")
        s.selectSubtitle("av-sub-en")
        f.last(.avPlayer)?.currentTime = 120

        await s.switchEngine(to: .vlc)

        let events = f.recorder.events
        #expect(events.contains(.loaded(.vlc, startAt: 120)))
        let closeIdx = events.firstIndex(of: .closed(.avPlayer))
        let loadIdx = events.firstIndex(of: .loaded(.vlc, startAt: 120))
        #expect(closeIdx != nil && loadIdx != nil && closeIdx! < loadIdx!)
        let vlc = f.last(.vlc)
        #expect(s.engine?.kind == .vlc)
        #expect(vlc?.selectedAudioID == "vlc-sv")
        #expect(vlc?.selectedSubtitleID == "vlc-sub-en")
        #expect(s.state == .playing)
    }

    @Test func switchWithoutMatchingLanguageKeepsDefaults() async {
        let avAudio = [track("av-sv", .audio, "sv")]
        let vlcAudio = [track("vlc-en", .audio, "en", isDefault: true)]
        let f = EngineFactory([
            .avPlayer: .succeeding(duration: 3000, audio: avAudio, subtitles: [], info: .unknown),
            .vlc: .succeeding(duration: 3000, audio: vlcAudio, subtitles: [], info: .unknown),
        ])
        let s = session(f)
        await s.start()
        #expect(f.last(.avPlayer)?.selectedAudioID == "av-sv")
        await s.switchEngine(to: .vlc)
        #expect(s.engine?.kind == .vlc)
        #expect(f.last(.vlc)?.selectedAudioID == nil)
        #expect(f.last(.vlc)?.selectedSubtitleID == nil)
        #expect(s.state == .playing)
    }

    @Test func switchFailureShowsErrorWithoutFallback() async {
        let f = EngineFactory([.avPlayer: .succeeding(), .vlc: .failing(.network)])
        let s = session(f)
        await s.start()
        await s.switchEngine(to: .vlc)
        #expect(f.recorder.kinds == [.avPlayer, .vlc])
        #expect(s.errorMessageKey == "playback.error.network")
        #expect(s.state == .failed(.network))
    }

    @Test func switchAfterFailedStartLoadsTargetFromResumePosition() async {
        let store = CountingStore()
        store.save(WatchProgress(key: key(.movie), position: 600, duration: 6000, watched: false, updatedAt: Date()))
        let f = EngineFactory([
            .avPlayer: .failing(.unsupportedFormat),
            .vlc: .succeeding(duration: 6000, audio: [track("a-en", .audio, "en")],
                              subtitles: [track("s-sv", .subtitle, "sv")], info: .unknown),
        ])
        let s = session(f, settings: PlaybackSettings(engine: .avPlayer), store: store)
        await s.start()
        #expect(s.errorMessageKey == "playback.error.unsupported")
        #expect(s.engine == nil)

        await s.switchEngine(to: .vlc)
        #expect(f.recorder.events.contains(.loaded(.vlc, startAt: 600)))
        #expect(s.engine?.kind == .vlc)
        #expect(s.state == .playing)
        #expect(s.errorMessageKey == nil)
        // Spårpreferenserna gäller när det inte finns något att bära över.
        #expect(f.last(.vlc)?.selectedSubtitleID == "s-sv")
    }

    @Test func switchWhileLoadingUsesPendingStartPosition() async {
        let store = CountingStore()
        store.save(WatchProgress(key: key(.movie), position: 600, duration: 6000, watched: false, updatedAt: Date()))
        let f = EngineFactory([.avPlayer: .hanging, .vlc: .succeeding()])
        let s = session(f, store: store)
        let task = Task { await s.start() }
        for _ in 0..<1000 where !f.recorder.events.contains(.loaded(.avPlayer, startAt: 600)) {
            await Task.yield()
        }
        await s.switchEngine(to: .vlc)
        await task.value
        #expect(f.recorder.events == [
            .made(.avPlayer), .loaded(.avPlayer, startAt: 600), .closed(.avPlayer),
            .made(.vlc), .loaded(.vlc, startAt: 600),
        ])
        #expect(s.state == .playing)
        #expect(s.errorMessageKey == nil)
        #expect(store.saves == 1) // bara förifyllningen; inget sparas från en motor som inte laddat klart
    }

    @Test func switchPreservesSubtitlesOff() async {
        let subs = [track("s-en", .subtitle, "en")]
        let f = EngineFactory([
            .avPlayer: .succeeding(duration: 3000, audio: [track("a-sv", .audio, "sv")], subtitles: subs, info: .unknown),
            .vlc: .succeeding(duration: 3000, audio: [track("v-sv", .audio, "sv")], subtitles: subs, info: .unknown),
        ])
        let s = session(f, settings: PlaybackSettings(tracks: TrackPreferences(subtitleMode: .off)))
        await s.start()
        #expect(f.last(.avPlayer)?.selectedSubtitleID == nil)
        await s.switchEngine(to: .vlc)
        #expect(f.last(.vlc)?.subtitleSelections == [nil])
        #expect(f.last(.vlc)?.selectedAudioID == "v-sv")
    }

    @Test func switchSavesBeforeClosingOldEngine() async {
        let f = EngineFactory([.avPlayer: .succeeding(), .vlc: .succeeding()])
        let store = CountingStore()
        let s = session(f, store: store)
        await s.start()
        f.last(.avPlayer)?.currentTime = 500
        await s.switchEngine(to: .vlc)
        #expect(store.saves == 1)
        #expect(store.progress(for: key(.movie))?.position == 500)
    }

    @Test func appliesTrackPreferencesOnStart() async {
        // Engelskt ljud + svensk text, läget foreignAudioOnly -> svensk text väljs.
        let f = EngineFactory([
            .avPlayer: .succeeding(duration: 3000,
                                   audio: [track("a-en", .audio, "en")],
                                   subtitles: [track("s-en", .subtitle, "en"), track("s-sv", .subtitle, "sv")],
                                   info: .unknown),
        ])
        let s = session(f, settings: PlaybackSettings(tracks: TrackPreferences(subtitleMode: .foreignAudioOnly)))
        await s.start()
        #expect(f.last(.avPlayer)?.selectedAudioID == "a-en")
        #expect(f.last(.avPlayer)?.selectedSubtitleID == "s-sv")
    }

    @Test func tickSavesEveryTenSeconds() async {
        // Senaste sparning räknas från start: tick vid 0, 5, 10, 15, 20 s -> sparning vid 10 och 20 s.
        let f = EngineFactory([.avPlayer: .succeeding()])
        let store = CountingStore()
        let clock = TestClock()
        let s = session(f, store: store, clock: clock)
        await s.start()
        for i in 0...4 {
            if i > 0 { clock.advance(5) }
            s.tick()
        }
        #expect(store.saves == 2)
    }

    @Test func stopSavesProgressImmediately() async {
        let f = EngineFactory([.avPlayer: .succeeding()])
        let store = CountingStore()
        let s = session(f, store: store)
        await s.start()
        f.last(.avPlayer)?.currentTime = 400
        s.stop()
        #expect(store.progress(for: key(.movie))?.position == 400)
        #expect(store.progress(for: key(.movie))?.duration == 1000)
        #expect(s.state == .idle)
        #expect(s.engine == nil)
        #expect(f.recorder.closeCount(.avPlayer) == 1)
        s.stop()
        #expect(f.recorder.closeCount(.avPlayer) == 1)
    }

    @Test func pauseAndSavePausesAndSaves() async {
        let f = EngineFactory([.avPlayer: .succeeding()])
        let store = CountingStore()
        let s = session(f, store: store)
        await s.start()
        f.last(.avPlayer)?.currentTime = 250
        s.pauseAndSave()
        #expect(s.state == .paused)
        #expect(store.progress(for: key(.movie))?.position == 250)
    }

    @Test func saveNowSavesWithoutPausingAndRestartsInterval() async {
        let f = EngineFactory([.avPlayer: .succeeding()])
        let store = CountingStore()
        let clock = TestClock()
        let s = session(f, store: store, clock: clock)
        await s.start()
        f.last(.avPlayer)?.currentTime = 321
        clock.advance(8)
        s.saveNow()
        #expect(store.saves == 1)
        #expect(store.progress(for: key(.movie))?.position == 321)
        #expect(s.state == .playing)
        // Intervallet räknas från saveNow: 8 s senare har 10 s inte gått.
        clock.advance(8)
        s.tick()
        #expect(store.saves == 1)
        clock.advance(2)
        s.tick()
        #expect(store.saves == 2)
    }

    @Test func liveNeverSavesProgress() async {
        let f = EngineFactory([.avPlayer: .succeeding(duration: nil, audio: [], subtitles: [], info: .unknown)])
        let store = CountingStore()
        let clock = TestClock()
        let s = session(f, request: request(kind: .live, container: "m3u8"), store: store, clock: clock)
        await s.start()
        #expect(f.recorder.events.contains(.loaded(.avPlayer, startAt: nil)))
        clock.advance(30)
        s.tick()
        s.pauseAndSave()
        s.stop()
        #expect(store.saves == 0)
        #expect(store.progress(for: key(.live)) == nil)
    }

    @Test func resumeUsesStoredProgress() async {
        let store = CountingStore()
        store.save(WatchProgress(key: key(.movie), position: 600, duration: 6000, watched: false, updatedAt: Date()))
        let f = EngineFactory([.avPlayer: .succeeding()])
        let s = session(f, store: store)
        await s.start()
        #expect(f.recorder.events.contains(.loaded(.avPlayer, startAt: 600)))
    }

    @Test func explicitStartAtOverridesStoredProgress() async {
        let store = CountingStore()
        store.save(WatchProgress(key: key(.movie), position: 600, duration: 6000, watched: false, updatedAt: Date()))
        let f = EngineFactory([.avPlayer: .succeeding()])
        let s = session(f, request: request(startAt: 0), store: store)
        await s.start()
        #expect(f.recorder.events.contains(.loaded(.avPlayer, startAt: 0)))
    }

    @Test func nextEpisodeOfferInLastThirtySeconds() async {
        let f = EngineFactory([.avPlayer: .succeeding()])
        let s = session(f, request: request(kind: .series))
        await s.start()
        f.last(.avPlayer)?.currentTime = 975
        #expect(s.nextEpisodeOffer)
        f.last(.avPlayer)?.currentTime = 900
        #expect(!s.nextEpisodeOffer)

        let fm = EngineFactory([.avPlayer: .succeeding()])
        let movie = session(fm, request: request(kind: .movie))
        await movie.start()
        fm.last(.avPlayer)?.currentTime = 975
        #expect(!movie.nextEpisodeOffer)
    }

    @Test func secretNeverInErrorOrState() async {
        let f = EngineFactory([.avPlayer: .failing(.network), .vlc: .failing(.unknown)])
        let s = session(f)
        await s.start()
        #expect(s.errorMessageKey != nil)
        #expect(!String(describing: s.state).contains(password))
        #expect(!String(describing: s.errorMessageKey).contains(password))
        #expect(!String(describing: s).contains(password))
    }
}
