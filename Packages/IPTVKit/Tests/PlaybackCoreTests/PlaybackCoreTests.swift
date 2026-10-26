import Foundation
import Testing
@testable import Core
@testable import PlaybackCore

@Test(arguments: [
    (Optional("mp4"), false, EnginePreference.automatic, EngineKind.avPlayer),
    ("m4v", false, .automatic, .avPlayer), ("mov", false, .automatic, .avPlayer),
    ("m3u8", false, .automatic, .avPlayer), ("m3u8", true, .automatic, .avPlayer),
    ("mkv", false, .automatic, .vlc), ("avi", false, .automatic, .vlc),
    ("ts", false, .automatic, .vlc),
    ("ts", true, .automatic, .vlc), (nil, false, .automatic, .avPlayer),
    ("MKV", false, .automatic, .vlc), (".mp4", false, .automatic, .avPlayer),
    ("mkv", false, .avPlayer, .avPlayer), ("mp4", false, .vlc, .vlc),
])
func initialEngine(c: String?, live: Bool, p: EnginePreference, e: EngineKind) {
    #expect(EngineSelector.initial(container: c, isLive: live, preference: p) == e)
}

@Test func fallbackOnlyOnceAndOnlyInAutomatic() {
    #expect(EngineSelector.fallback(after: .avPlayer, preference: .automatic, alreadyTried: [.avPlayer]) == .vlc)
    #expect(EngineSelector.fallback(after: .vlc, preference: .automatic, alreadyTried: [.avPlayer, .vlc]) == nil)
    #expect(EngineSelector.fallback(after: .vlc, preference: .automatic, alreadyTried: [.vlc]) == .avPlayer)
    #expect(EngineSelector.fallback(after: .avPlayer, preference: .avPlayer, alreadyTried: [.avPlayer]) == nil)
    #expect(EngineSelector.fallback(after: .avPlayer, preference: .vlc, alreadyTried: [.avPlayer]) == nil)
}

@Test func prefersSwedishAtmosAudio() {
    let a = [t("a1", "en", atmos: true, def: true), t("a2", "sv", ch: 2), t("a3", "sv", ch: 6, atmos: true)]
    #expect(TrackSelector.choose(audio: a, subtitles: [], prefs: .init()).audioID == "a3")
}

@Test func surroundOrderAndFallbacks() {
    let a = [t("a1", "sv", ch: 2), t("a2", "sv", ch: 6)]
    #expect(TrackSelector.choose(audio: a, subtitles: [], prefs: .init()).audioID == "a2")
    var off = TrackPreferences(); off.preferSurround = false
    #expect(TrackSelector.choose(audio: a, subtitles: [], prefs: off).audioID == "a1")
    let none = [t("x1", "de"), t("x2", "fr", def: true)]
    #expect(TrackSelector.choose(audio: none, subtitles: [], prefs: .init()).audioID == "x2")
    #expect(TrackSelector.choose(audio: [t("x1", "de"), t("x2", "fr")], subtitles: [], prefs: .init()).audioID == "x1")
    #expect(TrackSelector.choose(audio: [], subtitles: [], prefs: .init()) == TrackChoice(audioID: nil, subtitleID: nil))
}

@Test func subtitlesOnlyForForeignAudio() {
    let subs = [s("s1", "sv"), s("s2", "en")]
    #expect(TrackSelector.choose(audio: [t("a", "en")], subtitles: subs, prefs: .init()).subtitleID == "s1")
    #expect(TrackSelector.choose(audio: [t("a", "sv")], subtitles: subs, prefs: .init()).subtitleID == nil)
    #expect(TrackSelector.choose(audio: [t("a", "en")], subtitles: subs, prefs: .init(subtitleMode: .off)).subtitleID == nil)
    #expect(TrackSelector.choose(audio: [t("a", "sv")], subtitles: subs, prefs: .init(subtitleMode: .always)).subtitleID == "s1")
    #expect(TrackSelector.choose(audio: [t("a", "en")], subtitles: [s("s", "de")], prefs: .init(subtitleMode: .always)).subtitleID == nil)
}

@Test func forcedSubtitlesWhenAudioIsPreferred() {
    let subs = [s("s1", "sv"), s("f1", "swe", forced: true)]
    #expect(TrackSelector.choose(audio: [t("a", "sv")], subtitles: subs, prefs: .init()).subtitleID == "f1")
    #expect(TrackSelector.choose(audio: [t("a", "sv")], subtitles: subs, prefs: .init(subtitleMode: .off)).subtitleID == "f1")
    #expect(TrackSelector.choose(audio: [t("a", "en")], subtitles: [s("f", "sv", forced: true)], prefs: .init(subtitleMode: .off)).subtitleID == nil)
}

@Test func languageCodesNormalized() {
    for c in ["swe", "sv-SE", "SV", "swedish", "sve", "Swedish", "sv_SE"] { #expect(LanguageCode.normalize(c) == "sv") }
    for c in ["eng", "en-US", "english"] { #expect(LanguageCode.normalize(c) == "en") }
    #expect(LanguageCode.normalize("nob") == "no")
    #expect(LanguageCode.normalize("nb") == "no")
    #expect(LanguageCode.normalize("ger") == "de")
    #expect(LanguageCode.normalize("xx-YY") == "xx")
    #expect(LanguageCode.normalize("klingon") == nil)
    #expect(LanguageCode.normalize("") == nil)
    #expect(LanguageCode.normalize(nil) == nil)
    let a = [t("a1", "swe"), t("a2", "eng")]
    #expect(TrackSelector.choose(audio: a, subtitles: [], prefs: .init()).audioID == "a1")
}

@Test func matchingAcrossEngines() {
    let cur = t("old", "sv", ch: 6, atmos: true)
    let cands = [t("n1", "en"), t("n2", "swe", ch: 2), t("n3", "sv-SE", ch: 6, atmos: true)]
    #expect(TrackSelector.matching(cur, in: cands)?.id == "n3")
    #expect(TrackSelector.matching(t("o", "sv", ch: 6), in: [t("n2", "sv", ch: 2), t("n4", "sv", ch: 6)])?.id == "n4")
    #expect(TrackSelector.matching(t("o", "fr"), in: cands) == nil)
    #expect(TrackSelector.matching(nil, in: cands) == nil)
}

@Test func unknownDurationNeverMarksWatched() {
    for d in [nil, 0, .nan, .infinity] as [Double?] {
        #expect(ProgressPolicy.progress(key: k, position: 5000, duration: d, now: t0)?.watched == false)
    }
    #expect(ProgressPolicy.progress(key: k, position: 90, duration: 100, now: t0)?.watched == true)
    #expect(ProgressPolicy.progress(key: k, position: 89, duration: 100, now: t0)?.watched == false)
    #expect(ProgressPolicy.progress(key: liveKey, position: 90, duration: nil, now: t0) == nil)
    #expect(ProgressPolicy.progress(key: k, position: -5, duration: 100, now: t0)?.position == 0)
    #expect(ProgressPolicy.progress(key: k, position: .nan, duration: 100, now: t0)?.position == 0)
}

@Test func resumeRules() {
    #expect(ProgressPolicy.resumePosition(p(position: 29, duration: 100)) == nil)
    #expect(ProgressPolicy.resumePosition(p(position: 600, duration: 6000)) == 600)
    #expect(ProgressPolicy.resumePosition(p(position: 5900, duration: 6000, watched: true)) == nil)
    #expect(ProgressPolicy.resumePosition(nil) == nil)
}

@Test func userDefaultsStoreCapsAndOrders() {
    let d = UserDefaults(suiteName: "test.\(UUID())")!
    let st = UserDefaultsUserStateStore(defaults: d, capacity: 3)
    for i in 0..<5 { st.save(p(id: "\(i)", position: 100, duration: 1000, at: t0 + Double(i))) }
    #expect(st.continueWatching(playlistID: pid, limit: 10).map(\.key.providerID) == ["4", "3", "2"])
    #expect(st.progress(for: key("0")) == nil)
    let st2 = UserDefaultsUserStateStore(defaults: d, capacity: 3)
    #expect(st2.progress(for: key("4"))?.position == 100)
}

@Test func storeSurvivesCorruptData() {
    let d = UserDefaults(suiteName: "test.\(UUID())")!
    d.set(Data("garbage{".utf8), forKey: "userstate.progress.v1")
    let st = UserDefaultsUserStateStore(defaults: d)
    #expect(st.progress(for: k) == nil)
    #expect(st.continueWatching(playlistID: pid, limit: 5).isEmpty)
    st.save(p(position: 100, duration: 1000))
    #expect(st.progress(for: k)?.position == 100)
}

@Test(arguments: [0, 1])
func continueWatchingAndSeries(which: Int) {
    let st: any UserStateStore = which == 0 ? InMemoryUserStateStore()
        : UserDefaultsUserStateStore(defaults: UserDefaults(suiteName: "test.\(UUID())")!)
    st.save(p(id: "e1", series: "S", position: 100, duration: 1000, at: t0))
    st.save(p(id: "e2", series: "S", position: 200, duration: 1000, at: t0 + 10))
    st.save(p(id: "m1", position: 100, duration: 1000, at: t0 + 5))
    st.save(p(id: "m2", position: 950, duration: 1000, watched: true, at: t0 + 20))
    st.save(p(id: "m3", position: 10, duration: 1000, at: t0 + 30))
    #expect(st.continueWatching(playlistID: pid, limit: 10).map(\.key.providerID) == ["e2", "m1"])
    #expect(st.continueWatching(playlistID: pid, limit: 1).map(\.key.providerID) == ["e2"])
    #expect(st.continueWatching(playlistID: UUID(), limit: 10).isEmpty)
    st.save(p(id: "e3", series: "S", position: 990, duration: 1000, watched: true, at: t0 + 40))
    #expect(st.lastWatchedEpisode(playlistID: pid, seriesProviderID: "S")?.key.providerID == "e3")
    #expect(st.continueWatching(playlistID: pid, limit: 10).map(\.key.providerID) == ["m1"])
    #expect(st.lastWatchedEpisode(playlistID: pid, seriesProviderID: "X") == nil)
    st.remove(playlistID: pid)
    #expect(st.progress(for: key("m1")) == nil)
}

@Test func nextEpisodeCrossesSeason() {
    let all = [ep("a", 1, 1), ep("b", 1, 2), ep("c", 1, 10), ep("d", 2, 1), ep("e", 2, 3), ep("o", 1, 3, series: "OTHER")]
    #expect(NextEpisode.after(all[0], in: all)?.providerID == "b")
    #expect(NextEpisode.after(all[1], in: all)?.providerID == "c")
    #expect(NextEpisode.after(all[2], in: all)?.providerID == "d")
    #expect(NextEpisode.after(all[3], in: all)?.providerID == "e")
    #expect(NextEpisode.after(all[4], in: all) == nil)
    #expect(NextEpisode.after(all[4], in: all.reversed()) == nil)
    #expect(NextEpisode.after(all[0], in: all.reversed())?.providerID == "b")
}

@Test func settingsRoundTrip() {
    let d = UserDefaults(suiteName: "test.\(UUID())")!
    #expect(PlaybackSettings.load(from: d) == PlaybackSettings())
    var st = PlaybackSettings()
    st.engine = .vlc; st.previewsEnabled = false; st.tracks.subtitleMode = .always; st.tracks.audioLanguages = ["en"]
    st.save(to: d)
    #expect(PlaybackSettings.load(from: d) == st)
    d.set(Data("junk".utf8), forKey: "settings.playback.v1")
    #expect(PlaybackSettings.load(from: d) == PlaybackSettings())
}

@Test func defaultsAreAsSpecified() {
    let tp = TrackPreferences()
    #expect(tp.audioLanguages == ["sv", "en"] && tp.subtitleLanguages == ["sv", "en"])
    #expect(tp.subtitleMode == .foreignAudioOnly && tp.preferSurround)
}

@Test func infinitePositionDoesNotBlockPersistence() {
    #expect(ProgressPolicy.progress(key: k, position: .infinity, duration: 100, now: t0)?.position == 0)
    let d = UserDefaults(suiteName: "test.\(UUID())")!
    let st = UserDefaultsUserStateStore(defaults: d)
    st.save(p(id: "bad", position: .infinity, duration: .infinity))
    st.save(p(id: "ok", position: 100, duration: 1000, at: t0 + 1))
    #expect(st.progress(for: key("ok"))?.position == 100)
    #expect(st.progress(for: key("bad"))?.position == 0)
    let st2 = UserDefaultsUserStateStore(defaults: d)
    #expect(st2.progress(for: key("ok"))?.position == 100)
    #expect(st2.progress(for: key("bad")) != nil)
}

@Test func fiveHundredEntriesStaySmall() throws {
    let d = UserDefaults(suiteName: "test.\(UUID())")!
    let st = UserDefaultsUserStateStore(defaults: d)
    for i in 0..<600 {
        st.save(p(id: "\(UUID().uuidString)", series: "\(UUID().uuidString)", position: 1234.5, duration: 6000, at: t0 + Double(i)))
    }
    let data = try #require(d.data(forKey: "userstate.progress.v1"))
    #expect(data.count < 150_000)
    #expect(try JSONDecoder().decode([WatchProgress].self, from: data).count == 500)
}

@Test func settingsDecodeWithMissingFields() throws {
    let json = Data(#"{"engine":"vlc","tracks":{"audioLanguages":["en"]}}"#.utf8)
    let s = try JSONDecoder().decode(PlaybackSettings.self, from: json)
    #expect(s.engine == .vlc && s.tracks.audioLanguages == ["en"])
    #expect(s.previewsEnabled == true && s.tracks.preferSurround && s.tracks.subtitleMode == .foreignAudioOnly)
}
