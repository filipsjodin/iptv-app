# Fas 2 – Uppspelning: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Filmer, serieavsnitt och live-kanaler ska gå att spela på Apple TV och iPhone/iPad.
- Apples spelare (AVPlayer) används när det går, och VLC-motorn tar över automatiskt annars.
- Man kan byta motor mitt i uppspelningen, välja ljud- och textspår med förval och se en info-ruta.
- Appen har "Fortsätt titta", "Nästa avsnitt" och en inställningssida för spelarna.
- Dessutom ingår de punkter från fas 1 som sköts upp till den här fasen.

**Architecture:** Koden delas upp efter var den kan testas.
- **Ren beslutslogik** ligger i ett nytt plattformsoberoende target, `PlaybackCore` i IPTVKit, så att den kan testas på Windows. Det gäller motorval, spårval, regler för tittarposition och nästa avsnitt, samt lagring av användarstate.
- **Själva spelarna** ligger i ett nytt Apple-paket, `Packages/IPTVPlayback`:
  - `Playback` innehåller `PlayerEngine`-protokollet, `AVPlayerEngine` och `PlaybackSession`.
  - `VLCEngine` är ett tunt omslag kring VLCKit.
- **Användarstate** (position och sett-status) lagras i UserDefaults, eftersom tvOS saknar beständig lokal lagring utöver den. Katalogdatabasen ligger kvar i Caches.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation/AVKit, VLCKit (LGPL), GRDB 7, XcodeGen, GitHub Actions (`xcode-27`).

**Spec:** `docs/superpowers/specs/2026-10-25-iptv-app-design.md` §7 (uppspelning), §7.3 (fortsätt titta), §8.2 (anslutningsgräns), §11 (endast underlaget för nedladdning), §12 (stabila id:n), §14 fas 2.

## Global Constraints

- Lägsta OS-version: tvOS 27, iOS 27 och iPadOS 27. Swift 6 language mode med strict concurrency.
- Repot är **publikt**. Inga credentials, spellist-URL:er, serveradresser eller API-nycklar får hamna i git, CI-loggar, databasen, UserDefaults, loggar eller felmeddelanden. En strömmens fullständiga URL (som innehåller credentials) får bara finnas i minnet medan uppspelningen pågår och får aldrig loggas.
- Tredjepartsberoenden: GRDB och VLCKit (LGPL). **Inga GPL-beroenden** (spec §7.1).
- På Apple-plattformar skrivs `Core.Category`, aldrig bara `Category`. Lägg inte till explicita Library- eller GRDB-beroenden i det app-hostade testmålet `IPTV-iOSTests`.
- Kod i IPTVKit testas lokalt: `source scripts/swift-env.sh && cd Packages/IPTVKit && swift test`. Kod i IPTVPlatform, IPTVPlayback och Apps testas i GitHub Actions: push till grenen öppnar ett PR-utkast.
- Motorprotokollet ska göra det enkelt att lägga till en tredje motor (mpv) senare (spec §7.1).
- Profiler kommer i fas 3. Inställningarna i den här fasen gäller hela appen och lagras med en nyckel som kan flyttas till per profil senare (`settings.playback.v1`).
- Utanför den här fasen: OpenSubtitles, externa undertexter, synkjustering och textutseende (fas 6), TMDB och designen (fas 3), EPG (fas 4) samt nedladdningar (fas 7).
- Inställningar för sett-status och "Fortsätt titta" (spec §7.3):
  - Positionen sparas var 10:e sekund, vid paus och när spelaren stängs.
  - En titel räknas som sedd vid 90 %.
  - Erbjudandet om nästa avsnitt visas de sista 30 sekunderna, med en nedräkning på 10 sekunder.

## Review Focus

1. **En ström som inte startar** (död URL, 404, timeout eller ett format som inte stöds):
   - Automatiskt läge byter till VLC **en gång** och visar sedan ett vänligt fel.
   - Det får aldrig bli en oändlig loop, och felet innehåller ingen URL.
   - Test i Task 5: `failingBothEnginesShowsFriendlyErrorOnce`.
2. **Motorbyte när målmotorn saknar ett spår med samma språk:**
   - Appen behåller motorns standardspår och kraschar inte.
   - Positionen bevaras med högst 2 sekunders avvikelse.
   - Test i Task 5: `switchWithoutMatchingLanguageKeepsDefaults`.
3. **Okänd längd** (live, NaN, 0 eller oändlig):
   - Ingen position sparas som "sedd", och ingenting delas med noll.
   - Live sparar ingen position alls.
   - Test i Task 3: `unknownDurationNeverMarksWatched`.
4. **Spelaren stängs abrupt** (bakåtknapp, appen går till bakgrunden):
   - Positionen sparas direkt.
   - Test i Task 5: `stopSavesProgressImmediately`.
5. **Katalogen uppdateras efter att Xtream-avsnitt hämtats** när de behövdes:
   - Avsnitten och tittarpositionen finns kvar.
   - Test i Task 2: `xtreamRefreshKeepsLazyEpisodes`.

---

## Filstruktur

```
Packages/IPTVKit/
  Sources/Core/StreamLocator.swift                (ändras: fel för mall utan credentials)
  Sources/Providers/Xtream/XtreamClient.swift     (ändras: catalog(account:), minnessnål decodeRows)
  Sources/Core/ProviderCatalog.swift              (ändras: episodesComplete)
  Sources/PlaybackCore/  EngineKind.swift, EngineSelector.swift, MediaTrack.swift, TrackPreferences.swift,
                         TrackSelector.swift, ProgressPolicy.swift, WatchProgress.swift, UserStateStore.swift,
                         UserDefaultsUserStateStore.swift, PlaybackSettings.swift, NextEpisode.swift
  Tests/PlaybackCoreTests/...
Packages/IPTVPlatform/
  Sources/Library/AppDatabase.swift               (migrering v2)
  Sources/Library/LibraryStore.swift              (locator, avsnitt, tmdbID-COALESCE, kontoinfo)
  Sources/Library/PlaylistImporter.swift          (sparar kontoinfo)
  Sources/Secrets/KeychainCredentialStore.swift   (allPlaylistIDs)
Packages/IPTVPlayback/
  Package.swift
  Sources/Playback/  PlayerEngine.swift, AVPlayerEngine.swift, PlaybackSession.swift, VideoInfo.swift,
                     DisplayCriteria.swift, AudioSessionConfigurator.swift
  Sources/VLCEngine/ VLCPlayerEngine.swift, VLCTrackMapping.swift
  Sources/PlaybackTestSupport/ FakeEngine.swift, TestMedia.swift
  Tests/PlaybackTests/  Tests/VLCEngineTests/
Apps/Shared/
  Player/ PlayerScreen.swift, AVPlayerHost.swift, VLCPlayerHost.swift, PlayerControlsOverlay.swift,
          PlayerMenus.swift, NextEpisodeOverlay.swift, PlaybackInfoOverlay.swift
  Detail/ MovieDetailView.swift, SeriesDetailView.swift
  ContinueWatchingRow.swift
  Settings/ SettingsView.swift, EngineComparisonView.swift, FormatOverviewView.swift
  AppModel.swift (ändras), LibraryBrowserView.swift (ändras), PlaylistsView.swift (ändras)
```

---

### Task 1: IPTVKit – uppskjutna punkter från fas 1

**Files:**
- Modify: `Packages/IPTVKit/Sources/Core/StreamLocator.swift`
- Modify: `Packages/IPTVKit/Sources/Core/ProviderCatalog.swift`
- Modify: `Packages/IPTVKit/Sources/Providers/Xtream/XtreamClient.swift`
- Modify: `Packages/IPTVKit/Sources/Providers/M3UMapper.swift`
- Test: `Tests/CoreTests/StreamLocatorTests.swift`, `Tests/ProvidersTests/XtreamClientTests.swift`

**Interfaces:**
- Produces:
  - `ProviderCatalog.episodesComplete: Bool`. M3U ger `true` och Xtream ger `false`, eftersom Xtream-avsnitt hämtas först när de behövs. Standardvärdet i `init` är `true`.
  - `XtreamClient.catalog(account: XtreamAccount? = nil) async throws -> ProviderCatalog`. När ett konto skickas in görs ingen ny autentisering.
  - `CoreError.missingCredentials`, som kastas av `StreamLocator.resolve` när en `.template` innehåller `{username}` eller `{password}` men secret saknar sådana uppgifter.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@Test(arguments: ["p+w", "p/w", "p%w", "påß wörd", "ü🙂"])
func specialPasswordsRoundTrip(pw: String) throws {
    let s = PlaylistSecret.xtream(server: URL(string: "http://h.example:8080/")!, username: "u", password: pw)
    let url = try StreamLocator.xtream(kind: .movie, streamID: "1", container: "mkv").resolve(with: s)
    #expect(url.pathComponents[3].removingPercentEncoding == pw)
    #expect(url.absoluteString.hasPrefix("http://h.example:8080/movie/u/"))   // ingen dubbel snedstreck
}
@Test func templateNeedingCredentialsWithoutThemThrows() {
    #expect(throws: CoreError.missingCredentials) {
        try StreamLocator.template("{server}/x/{username}/{password}/1.ts")
            .resolve(with: .m3u(url: URL(string: "http://h.example/list.m3u")!, epgURL: nil))
    }
}
@Test func catalogWithPrefetchedAccountSkipsAuth() async throws {
    let stub = StubHTTPClient(standardFixtures)
    let c = XtreamClient(server: URL(string: "http://h.example")!, username: "u", password: "p", http: stub)
    let acc = try await c.account()
    let before = stub.requestCount(action: "")
    _ = try await c.catalog(account: acc)
    #expect(stub.requestCount(action: "") == before)
}
@Test func xtreamCatalogMarksEpisodesIncomplete() async throws {
    #expect(try await xtreamClient(fixtures: standardFixtures).catalog().episodesComplete == false)
}
```

Lägg till `requestCount(action:)` i `StubHTTPClient` i `ProvidersTestSupport`.

- [ ] **Step 2:** Kör `source scripts/swift-env.sh && cd Packages/IPTVKit && swift test`. Förväntat resultat: FAIL.
- [ ] **Step 3: Implementera.**
  - `decodeRows` ska inte längre kopiera hela kroppen till en `String`. Avgör tom, `null`, `[]` eller `{}` genom att läsa de första och sista bytena som inte är blanktecken.
  - `M3UMapper` sätter `episodesComplete = true`.
- [ ] **Step 4:** Kör `swift test`. Förväntat resultat: PASS. Pusha sedan och kontrollera att CI är grönt.
- [ ] **Step 5:** Commit: `feat(kit): catalog(account:), episodesComplete, credential-fel för mallar och snålare avkodning`.

---

### Task 2: Library – migrering v2, avsnitt, locator, kontoinfo och Keychain-städning

**Files:**
- Modify: `Packages/IPTVPlatform/Sources/Library/AppDatabase.swift`, `LibraryStore.swift`, `PlaylistImporter.swift`, `Records.swift`
- Modify: `Packages/IPTVPlatform/Sources/Secrets/KeychainCredentialStore.swift`
- Modify: `Packages/IPTVKit/Sources/Core/CredentialStore.swift` (`InMemoryCredentialStore` får `allPlaylistIDs`)
- Test: `Tests/LibraryTests/LibraryStoreV2Tests.swift`, `Tests/LibraryTests/PlaylistImporterTests.swift`, `Tests/SecretsTests/KeychainCredentialStoreTests.swift`

**Interfaces:**
- Consumes: `ProviderCatalog.episodesComplete` och `XtreamClient.catalog(account:)` från Task 1.
- Produces:
  - Migreringen `"v2"`:
    - `playlist` får `maxConnections INTEGER`, `expiresAt REAL` och `accountStatus TEXT`.
    - Indexen `movie_title ON movie(playlistID, title COLLATE NOCASE)` och `series_title ON series(playlistID, title COLLATE NOCASE)` läggs till.
  - `public struct PlaylistAccountInfo: Sendable, Equatable { maxConnections: Int?; expiresAt: Date?; status: String? }`
  - `LibraryStore.accountInfo(playlistID: UUID) throws -> PlaylistAccountInfo`
  - `LibraryStore.setAccountInfo(_: PlaylistAccountInfo, playlistID: UUID) throws`
  - `LibraryStore.locator(playlistID: UUID, kind: ContentKind, providerID: String) throws -> StreamLocator?`. För `.series` letar den i avsnittstabellen efter avsnittets providerID.
  - `LibraryStore.episodes(playlistID: UUID, seriesProviderID: String) throws -> [Episode]`, sorterade efter säsong och nummer.
  - `LibraryStore.upsertEpisodes(_: [Episode], seriesProviderID: String, playlistID: UUID, now: Date) throws`. Den ersätter avsnitten för just den serien.
  - `LibraryStore.movie(playlistID: UUID, providerID: String) throws -> Movie?`
  - `LibraryStore.series(playlistID: UUID, providerID: String) throws -> Series?`
  - Ändrat beteende i `replaceCatalog`:
    - Om `episodesComplete == false` behålls befintliga avsnitt vars serie finns kvar, och bara avsnitt till borttagna serier raderas.
    - `tmdbID = COALESCE(excluded.tmdbID, <tabell>.tmdbID)` för filmer och serier.
  - `PlaylistImporter` hämtar `account()` för Xtream först, skickar kontot vidare till `catalog(account:)` och sparar `setAccountInfo` i samma flöde efter en lyckad `replaceCatalog`.
  - `CredentialStore` får `func allPlaylistIDs() throws -> [UUID]`. Både Keychain och InMemory implementerar den. Keychain använder `kSecMatchLimitAll` och `kSecReturnAttributes` och returnerar bara konton som går att tolka som UUID.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@Test func xtreamRefreshKeepsLazyEpisodes() throws {
    let s = try storeWithSeries(["s1", "s2"]); let pid = s.pid
    try s.store.upsertEpisodes([ep("e1", series: "s1"), ep("e2", series: "s2")], seriesProviderID: "s1", playlistID: pid, now: t0)
    try s.store.replaceCatalog(catalog(series: ["s1"], episodesComplete: false), playlistID: pid, now: t1)
    #expect(try s.store.episodes(playlistID: pid, seriesProviderID: "s1").map(\.providerID) == ["e1"])
    #expect(try s.store.episodes(playlistID: pid, seriesProviderID: "s2").isEmpty)  // serien borta → avsnitt borta
}
@Test func m3uRefreshReplacesEpisodes() throws { /* episodesComplete true → avsnitt som saknas i nya katalogen tas bort */ }
@Test func tmdbIDSurvivesRefreshWithoutOne() throws {
    // film "1" med tmdbID 42 → ny katalog med samma film utan tmdbID → tmdbID är fortfarande 42
}
@Test func locatorLookupForMovieAndEpisode() throws {
    #expect(try store.locator(playlistID: pid, kind: .movie, providerID: "1") == .xtream(kind: .movie, streamID: "1", container: "mkv"))
    #expect(try store.locator(playlistID: pid, kind: .series, providerID: "e1") != nil)
    #expect(try store.locator(playlistID: pid, kind: .movie, providerID: "missing") == nil)
}
@Test func importerStoresXtreamAccountInfo() async throws {
    // standardFixtures: max_connections "2", exp_date 1798761600
    #expect(try store.accountInfo(playlistID: id) == PlaylistAccountInfo(maxConnections: 2, expiresAt: Date(timeIntervalSince1970: 1_798_761_600), status: "Active"))
}
@Test func keychainListsPlaylistIDs() throws { /* två sparade + en icke-UUID-post → allPlaylistIDs ger exakt de två */ }
```

- [ ] **Step 2:** Pusha och kontrollera i CI. Förväntat resultat: FAIL.
- [ ] **Step 3:** Implementera enligt Interfaces. Lägg till `v2` som en ny migrering och ändra inte `v1`.
- [ ] **Step 4:** Kontrollera att CI och Nightly blir gröna. Prestandatestet från fas 1 ska fortfarande hålla gränserna.
- [ ] **Step 5:** Commit: `feat(library): migrering v2, avsnitt per serie, locator-uppslag, kontoinfo, Keychain-lista`.

---

### Task 3: PlaybackCore – motorval, spårval, tittarposition och användarstate

**Files:**
- Create: `Packages/IPTVKit/Sources/PlaybackCore/*.swift` (se filstrukturen ovan)
- Modify: `Packages/IPTVKit/Package.swift` (target och product `PlaybackCore`, beroende Core, testtarget `PlaybackCoreTests`)
- Test: `Packages/IPTVKit/Tests/PlaybackCoreTests/*.swift`

**Interfaces:**
- Produces (alla `public` och `Sendable`):
  - `enum EngineKind: String, Codable { case avPlayer, vlc }`
  - `enum EnginePreference: String, Codable, CaseIterable { case automatic, avPlayer, vlc }`
  - `enum EngineSelector`:
    - `static func initial(container: String?, isLive: Bool, preference: EnginePreference) -> EngineKind`
    - `static func fallback(after failed: EngineKind, preference: EnginePreference, alreadyTried: Set<EngineKind>) -> EngineKind?`
  - `struct MediaTrack: Hashable, Codable { id: String; kind: TrackKind; languageCode: String?; title: String; codec: String?; channelCount: Int?; isAtmos: Bool; isDefault: Bool; isForced: Bool }` och `enum TrackKind: String, Codable { case audio, subtitle }`
  - `enum SubtitleMode: String, Codable, CaseIterable { case off, always, foreignAudioOnly }`
  - `struct TrackPreferences: Codable, Equatable { audioLanguages: [String]; subtitleMode: SubtitleMode; subtitleLanguages: [String]; preferSurround: Bool }`. Standardvärden: `["sv", "en"]`, `.foreignAudioOnly`, `["sv", "en"]` och `true`.
  - `struct TrackChoice: Equatable { audioID: String?; subtitleID: String? }`
  - `enum TrackSelector`:
    - `static func choose(audio: [MediaTrack], subtitles: [MediaTrack], prefs: TrackPreferences) -> TrackChoice`
    - `static func matching(_ track: MediaTrack?, in candidates: [MediaTrack]) -> MediaTrack?`. Matchar på språk och, vid flera träffar, på samma Atmos- eller kanalprofil. Används vid motorbyte.
  - `struct WatchProgress: Codable, Equatable { key: ProgressKey; position: Double; duration: Double?; watched: Bool; updatedAt: Date }` och `struct ProgressKey: Hashable, Codable { playlistID: UUID; kind: ContentKind; providerID: String; seriesProviderID: String? }`
  - `enum ProgressPolicy`:
    - `static let saveInterval: Duration = .seconds(10)`
    - `static let watchedFraction = 0.9`
    - `static let minimumResume: Double = 30`
    - `static let nextEpisodeLead: Double = 30`
    - `static let nextEpisodeCountdown = 10`
    - `static func progress(key:position:duration:now:) -> WatchProgress?`. Returnerar `nil` för live, och `watched` kräver en ändlig längd större än 0.
    - `static func resumePosition(_: WatchProgress?) -> Double?`. Returnerar `nil` om positionen är under `minimumResume` eller om titeln är sedd.
  - `protocol UserStateStore: Sendable`:
    - `func progress(for: ProgressKey) -> WatchProgress?`
    - `func save(_: WatchProgress)`
    - `func continueWatching(playlistID: UUID, limit: Int) -> [WatchProgress]`. Returnerar osedda titlar med en resume-position, nyast först.
    - `func lastWatchedEpisode(playlistID: UUID, seriesProviderID: String) -> WatchProgress?`
    - `func remove(playlistID: UUID)`
  - `final class InMemoryUserStateStore` och `final class UserDefaultsUserStateStore(defaults: UserDefaults, key: String = "userstate.progress.v1", capacity: Int = 1000)`. Den senare kastar ut de äldsta posterna när kapaciteten överskrids.
  - `struct PlaybackSettings: Codable, Equatable { engine: EnginePreference = .automatic; tracks: TrackPreferences = .init(); previewsEnabled: Bool = true }`, med `static func load(from: UserDefaults) -> PlaybackSettings` och `func save(to: UserDefaults)` under nyckeln `"settings.playback.v1"`.
  - `enum NextEpisode { static func after(_ current: Episode, in all: [Episode]) -> Episode? }`. Nästa avsnitt i samma säsong, annars första avsnittet i nästa säsong.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@Test(arguments: [
    ("mp4", false, EnginePreference.automatic, EngineKind.avPlayer),
    ("m4v", false, .automatic, .avPlayer), ("mov", false, .automatic, .avPlayer),
    ("m3u8", false, .automatic, .avPlayer), ("m3u8", true, .automatic, .avPlayer),
    ("mkv", false, .automatic, .vlc), ("avi", false, .automatic, .vlc),
    ("ts", false, .automatic, .vlc),          // progressiv TS spelas inte av AVPlayer
    ("ts", true, .automatic, .vlc), (nil, false, .automatic, .avPlayer),
    ("mkv", false, .avPlayer, .avPlayer), ("mp4", false, .vlc, .vlc),
])
func initialEngine(c: String?, live: Bool, p: EnginePreference, e: EngineKind) {
    #expect(EngineSelector.initial(container: c, isLive: live, preference: p) == e)
}
@Test func fallbackOnlyOnceAndOnlyInAutomatic() {
    #expect(EngineSelector.fallback(after: .avPlayer, preference: .automatic, alreadyTried: [.avPlayer]) == .vlc)
    #expect(EngineSelector.fallback(after: .vlc, preference: .automatic, alreadyTried: [.avPlayer, .vlc]) == nil)
    #expect(EngineSelector.fallback(after: .avPlayer, preference: .avPlayer, alreadyTried: [.avPlayer]) == nil)
}
@Test func prefersSwedishAtmosAudio() {
    let a = [t("a1", "en", atmos: true, def: true), t("a2", "sv", ch: 2), t("a3", "sv", ch: 6, atmos: true)]
    #expect(TrackSelector.choose(audio: a, subtitles: [], prefs: .init()).audioID == "a3")
}
@Test func subtitlesOnlyForForeignAudio() {
    let subs = [s("s1", "sv"), s("s2", "en")]
    #expect(TrackSelector.choose(audio: [t("a", "en")], subtitles: subs, prefs: .init()).subtitleID == "s1")
    #expect(TrackSelector.choose(audio: [t("a", "sv")], subtitles: subs, prefs: .init()).subtitleID == nil)
    #expect(TrackSelector.choose(audio: [t("a", "en")], subtitles: subs, prefs: .init(subtitleMode: .off)).subtitleID == nil)
}
@Test func forcedSubtitlesWhenAudioIsPreferred() { /* svenskt ljud + forced svensk text → forced väljs även i läget foreignAudioOnly */ }
@Test func languageCodesNormalized() { /* "swe", "sv-SE", "SV", "swedish" matchar alla "sv"; "eng", "en-US" matchar "en" */ }
@Test func unknownDurationNeverMarksWatched() {
    for d in [nil, 0, .nan, .infinity] as [Double?] {
        #expect(ProgressPolicy.progress(key: k, position: 5000, duration: d, now: t0)?.watched == false)
    }
    #expect(ProgressPolicy.progress(key: k, position: 90, duration: 100, now: t0)?.watched == true)
    #expect(ProgressPolicy.progress(key: liveKey, position: 90, duration: nil, now: t0) == nil)
}
@Test func resumeRules() {
    #expect(ProgressPolicy.resumePosition(p(position: 29, duration: 100)) == nil)
    #expect(ProgressPolicy.resumePosition(p(position: 600, duration: 6000)) == 600)
    #expect(ProgressPolicy.resumePosition(p(position: 5900, duration: 6000, watched: true)) == nil)
}
@Test func userDefaultsStoreCapsAndOrders() {
    let d = UserDefaults(suiteName: "test.\(UUID())")!
    let st = UserDefaultsUserStateStore(defaults: d, capacity: 3)
    for i in 0..<5 { st.save(p(id: "\(i)", position: 100, duration: 1000, at: t0 + Double(i))) }
    #expect(st.continueWatching(playlistID: pid, limit: 10).map(\.key.providerID) == ["4", "3", "2"])
    #expect(st.progress(for: key("0")) == nil)
}
@Test func storeSurvivesCorruptData() { /* skräpdata under nyckeln → tomt lager, ingen krasch, nästa save fungerar */ }
@Test func nextEpisodeCrossesSeason() { /* S1E10 är sista i S1 → S2E1; sista avsnittet totalt → nil; luckor i numreringen hanteras */ }
@Test func settingsRoundTrip() { /* save, sedan load ger samma värde; skräp under nyckeln ger standardvärden */ }
```

- [ ] **Step 2:** Kör `swift test --filter PlaybackCoreTests`. Förväntat resultat: FAIL.
- [ ] **Step 3: Implementera.**
  - Språknormalisering: ISO 639-1 och -2 samt engelska namn för minst sv, en, no/nb, da, fi, de, fr, es, it, ar, tr, pl, nl och pt, med regionsuffix borttaget.
  - Ljudval: första språket i preferensordningen som finns. Inom språket, om `preferSurround`: Atmos före flest kanaler före övriga. Saknas alla preferensspråk används standardspåret eller det första.
- [ ] **Step 4:** Kör `swift test`. Förväntat resultat: PASS. Kontrollera också att jobbet `kit-tests` i CI är grönt på Linux.
- [ ] **Step 5:** Commit: `feat(playback-core): motorval, spårval, tittarposition och användarstate`.

---

### Task 4: IPTVPlayback-paketet – PlayerEngine-protokoll och AVPlayerEngine

**Files:**
- Create: `Packages/IPTVPlayback/Package.swift` (tools 6.2; `.iOS("27.0")`, `.tvOS("27.0")`, `.macOS("15.0")`; beroenden på `../IPTVKit` med produkterna Core och PlaybackCore)
- Create: `Sources/Playback/PlayerEngine.swift`, `VideoInfo.swift`, `AVPlayerEngine.swift`, `DisplayCriteria.swift`, `AudioSessionConfigurator.swift`
- Create: `Sources/PlaybackTestSupport/FakeEngine.swift`, `TestMedia.swift`
- Test: `Tests/PlaybackTests/AVPlayerEngineTests.swift`
- Modify: `.github/workflows/ci.yml`, så att jobbet `apple` också kör `swift test` i `Packages/IPTVPlayback`

**Interfaces:**
- Consumes: `EngineKind`, `MediaTrack` och `TrackKind` från Task 3.
- Produces:
  - `enum PlaybackState: Equatable, Sendable { case idle, loading, playing, paused, buffering, ended, failed(PlaybackFailure) }` och `enum PlaybackFailure: Error, Equatable, Sendable { case unsupportedFormat, network, timeout, unknown }`. Inga strängar i felen.
  - `struct VideoInfo: Equatable, Sendable { width: Int?; height: Int?; dynamicRange: DynamicRange; videoCodec: String?; audioDescription: String?; bitrate: Double?; frameRate: Double? }` och `enum DynamicRange: String, Sendable { case sdr, hdr10, hlg, dolbyVision }`. Den har `var summary: String` som ger till exempel `"2160p · Dolby Vision · Atmos"`.
  - `@MainActor protocol PlayerEngine: AnyObject`:
    - `var kind: EngineKind { get }`
    - `var state: PlaybackState { get }`
    - `var currentTime: Double { get }`
    - `var duration: Double? { get }`
    - `var audioTracks: [MediaTrack] { get }`
    - `var subtitleTracks: [MediaTrack] { get }`
    - `var selectedAudioID: String? { get }`
    - `var selectedSubtitleID: String? { get }`
    - `var videoInfo: VideoInfo { get }`
    - `var onStateChange: ((PlaybackState) -> Void)? { get set }`
    - `func load(url: URL, startAt: Double?) async throws`. Den kastar `PlaybackFailure` och har en timeout på 15 s tills strömmen är redo.
    - `func play()`, `func pause()`, `func seek(to seconds: Double) async`
    - `func select(audioID: String?)`, `func select(subtitleID: String?)`
    - `func close()`
  - `@MainActor final class AVPlayerEngine: PlayerEngine`, som exponerar `let player: AVPlayer` för `AVPlayerViewController`. Spår mappas från `AVMediaSelectionGroup` (legible och audible), och spårets id är `"\(index)"` inom gruppen. `isAtmos` kommer från formatbeskrivningen (E-AC-3 JOC). Dynamic range kommer från `AVAssetTrack.mediaCharacteristics` och formatbeskrivningens tillägg.
  - `enum DisplayCriteriaHelper`: på tvOS sätts `AVDisplayManager.preferredDisplayCriteria` från `AVAsset.preferredDisplayCriteria` vid laddning, och återställs till `nil` vid `close()`. På iOS gör den ingenting.
  - `enum AudioSessionConfigurator { static func configureForPlayback() throws }` med `.playback`, mode `.moviePlayback` och `supportsMultichannelContent`/spatial där plattformen stöder det.
  - `PlaybackTestSupport`:
    - `@MainActor final class FakeEngine: PlayerEngine`, som är skriptbar: lyckas, misslyckas med en given `PlaybackFailure`, givna spår och given längd. Den räknar `close()`-anrop.
    - `enum TestMedia { static func makeMovie(seconds: Int) async throws -> URL }`. Den skapar en H.264-mp4 med `AVAssetWriter` i en temporär katalog.

- [ ] **Step 1: Skriv tester som misslyckas** (de körs på macOS-runnern)

```swift
@MainActor @Test func playsGeneratedMovieAndReportsDuration() async throws {
    let url = try await TestMedia.makeMovie(seconds: 2)
    let e = AVPlayerEngine()
    try await e.load(url: url, startAt: nil)
    #expect(abs((e.duration ?? 0) - 2) < 0.2)
    #expect(e.videoInfo.dynamicRange == .sdr)
    e.close(); #expect(e.state == .idle)
}
@MainActor @Test func startAtSeeks() async throws { /* startAt 1.0 → currentTime >= 0.9 efter laddning */ }
@MainActor @Test func missingFileFailsFast() async {
    await #expect(throws: PlaybackFailure.self) { try await AVPlayerEngine().load(url: URL(fileURLWithPath: "/nonexistent.mp4"), startAt: nil) }
}
@MainActor @Test func unreachableHostFailsAsNetworkOrTimeout() async { /* http://203.0.113.7:9/x.m3u8 → .network eller .timeout inom 20 s */ }
@Test func summaryFormatting() {
    #expect(VideoInfo(width: 3840, height: 2160, dynamicRange: .dolbyVision, videoCodec: "hvc1", audioDescription: "Atmos", bitrate: 18_000_000, frameRate: 24).summary == "2160p · Dolby Vision · Atmos")
    #expect(VideoInfo(width: 1920, height: 1080, dynamicRange: .sdr, videoCodec: nil, audioDescription: nil, bitrate: nil, frameRate: nil).summary == "1080p")
}
```

- [ ] **Step 2:** Pusha och kontrollera i CI. Förväntat resultat: FAIL.
- [ ] **Step 3:** Implementera. KVO och observatörer tas bort i `close()`. Inget `print` och ingen loggning av URL:er.
- [ ] **Step 4:** Kontrollera att CI blir grönt.
- [ ] **Step 5:** Commit: `feat(playback): PlayerEngine-protokoll och AVPlayerEngine`.

---

### Task 5: PlaybackSession – motorval, reservmotor, byte, spårval och tittarposition

**Files:**
- Create: `Packages/IPTVPlayback/Sources/Playback/PlaybackSession.swift`
- Test: `Packages/IPTVPlayback/Tests/PlaybackTests/PlaybackSessionTests.swift`

**Interfaces:**
- Consumes: `PlayerEngine`, `FakeEngine` (Task 4), `EngineSelector`, `TrackSelector`, `ProgressPolicy`, `UserStateStore`, `PlaybackSettings`, `ProgressKey` (Task 3) samt `StreamLocator` och `PlaylistSecret` (Core).
- Produces:
  - `struct PlaybackRequest: Sendable { key: ProgressKey; title: String; locator: StreamLocator; container: String?; isLive: Bool; startAt: Double? }`
  - `@MainActor @Observable final class PlaybackSession`:
    - `init(request: PlaybackRequest, secret: PlaylistSecret, settings: PlaybackSettings, userState: UserStateStore, makeEngine: @MainActor (EngineKind) -> PlayerEngine)`
    - `private(set) var engine: PlayerEngine?`
    - `private(set) var state: PlaybackState`
    - `private(set) var errorMessageKey: String?`. Sätts till `"playback.error.unsupported"`, `"playback.error.network"` eller `"playback.error.generic"`.
    - `func start() async`
    - `func switchEngine(to: EngineKind) async`
    - `func selectAudio(_ id: String?)`
    - `func selectSubtitle(_ id: String?)`
    - `func tick()`, som anropas av värdvyn ungefär varje sekund. Den sparar positionen var `saveInterval`.
    - `func pauseAndSave()`
    - `func stop()`, som sparar positionen och stänger motorn.
    - `var nextEpisodeOffer: Bool`, som är true när det återstår högst `nextEpisodeLead` sekunder av ett serieavsnitt.

- [ ] **Step 1: Skriv tester som misslyckas** (FakeEngine, inget nätverk)

```swift
@MainActor @Test func automaticFallsBackToVLCOnce() async {
    let made = Recorder()
    let s = session(container: "mp4", engines: [.avPlayer: .failing(.unsupportedFormat), .vlc: .succeeding()], recorder: made)
    await s.start()
    #expect(made.kinds == [.avPlayer, .vlc]); #expect(s.state == .playing); #expect(made.closed[.avPlayer] == 1)
}
@MainActor @Test func failingBothEnginesShowsFriendlyErrorOnce() async {
    let s = session(container: "mp4", engines: [.avPlayer: .failing(.network), .vlc: .failing(.network)])
    await s.start()
    #expect(s.errorMessageKey == "playback.error.network"); #expect(made.kinds.count == 2)
}
@MainActor @Test func explicitPreferenceNeverFallsBack() async { /* settings.engine = .avPlayer, misslyckas → ingen VLC, fel visas */ }
@MainActor @Test func previousEngineClosedBeforeNextOpens() async {
    // spelar inspelningsordningen: close(avPlayer) sker före load(vlc), vilket krävs vid max_connections == 1
}
@MainActor @Test func switchPreservesPositionAndLanguages() async {
    // AV på 120 s med svenskt ljud + engelsk text → switchEngine(.vlc) → vlc laddad med startAt ≈ 120 och spår per språk
}
@MainActor @Test func switchWithoutMatchingLanguageKeepsDefaults() async { /* VLC saknar svenska → ljud-id förblir motorns standard, ingen krasch */ }
@MainActor @Test func appliesTrackPreferencesOnStart() async { /* engelskt ljud + svensk text finns, läget foreignAudioOnly → svensk text vald */ }
@MainActor @Test func tickSavesEveryTenSeconds() async { /* tick vid 0, 5, 10, 15 s (injicerad klocka) → exakt 2 sparningar */ }
@MainActor @Test func stopSavesProgressImmediately() async { /* position 400/1000 → stop() → store innehåller 400 */ }
@MainActor @Test func liveNeverSavesProgress() async { /* isLive → store tom efter tick och stop */ }
@MainActor @Test func resumeUsesStoredProgress() async { /* store 600/6000 → engine.load(startAt: 600) */ }
@MainActor @Test func nextEpisodeOfferInLastThirtySeconds() async { /* 975/1000 → true; 900/1000 → false; film → alltid false */ }
@MainActor @Test func secretNeverInErrorOrState() async { /* misslyckad start → String(describing: s.state) och errorMessageKey innehåller inte lösenordet */ }
```

Injicera en klocka via `init(... now: @escaping () -> Date = Date.init)`.

- [ ] **Step 2:** Pusha och kontrollera i CI. Förväntat resultat: FAIL.
- [ ] **Step 3:** Implementera.
  - URL:en löses upp med `request.locator.resolve(with: secret)` och hålls bara i en lokal variabel i `start()` och `switchEngine`.
  - Vid misslyckad uppslagning: `errorMessageKey = "playback.error.generic"`.
  - Ljudsessionen konfigureras vid `start()`.
- [ ] **Step 4:** Kontrollera att CI blir grönt.
- [ ] **Step 5:** Commit: `feat(playback): PlaybackSession med reservmotor, motorbyte, spårval och tittarposition`.

---

### Task 6: VLCEngine

**Files:**
- Modify: `Packages/IPTVPlayback/Package.swift` (beroende på VLCKit, target `VLCEngine`, testtarget `VLCEngineTests`)
- Create: `Sources/VLCEngine/VLCPlayerEngine.swift`, `VLCTrackMapping.swift`
- Test: `Tests/VLCEngineTests/VLCTrackMappingTests.swift`, `VLCPlayerEngineTests.swift`

**Interfaces:**
- Consumes: `PlayerEngine`, `PlaybackState`, `PlaybackFailure`, `VideoInfo` (Task 4) och `MediaTrack` (Task 3).
- Produces:
  - `@MainActor final class VLCPlayerEngine: PlayerEngine`, som exponerar `let drawable: UIView` för värdvyn.
  - `enum VLCTrackMapping { static func tracks(from descriptions: [(index: Int32, name: String)], kind: TrackKind) -> [MediaTrack] }`. Den tolkar språk ur namn som `"Track 1 - [Swedish]"`, `"English (E-AC3 5.1)"` och `"sv"`. `isAtmos` blir true om namnet innehåller "Atmos" eller "JOC", och spår med index −1 ("Disable") hoppas över.

- [ ] **Step 1: Beslut om hur VLCKit integreras.** Gör detta först och dokumentera i rapporten.
  1. Om `https://code.videolan.org/videolan/VLCKit` har en `Package.swift` med en stabil tagg som stöder iOS och tvOS (VLCKit 4): använd den via SwiftPM.
  2. Annars: ladda ner det officiella `VLCKit.xcframework` (iOS och tvOS i samma) från `download.videolan.org`. Zippa om det, publicera det som en release-asset i det här repot (`gh release create vlckit-<version>`) och använd `.binaryTarget(url:checksum:)`.
  3. Om bara separata MobileVLCKit/TVVLCKit 3.x finns: två binära targets villkorade per plattform med `.when(platforms:)`.
  
  Licensen (LGPL-2.1) noteras i README under "Licenser".
- [ ] **Step 2: Skriv tester som misslyckas**

```swift
@Test func mapsVLCTrackNames() {
    let t = VLCTrackMapping.tracks(from: [(-1, "Disable"), (1, "Track 1 - [Swedish]"), (2, "English (E-AC3 5.1) - Atmos")], kind: .audio)
    #expect(t.map(\.id) == ["1", "2"]); #expect(t[0].languageCode == "sv"); #expect(t[1].isAtmos); #expect(t[1].channelCount == 6)
}
@MainActor @Test func vlcPlaysGeneratedMovie() async throws {
    let url = try await TestMedia.makeMovie(seconds: 2)
    let e = VLCPlayerEngine(); try await e.load(url: url, startAt: nil)
    #expect(e.state == .playing || e.state == .paused); e.close()
}
```

Testet med riktig uppspelning körs bara om VLCKit kan initieras i testprocessen. Annars markeras det `.disabled("VLCKit kräver app-värd")`, med motivering i rapporten.
- [ ] **Step 3:** Implementera.
  - Tillståndsövergångar sker via `VLCMediaPlayerDelegate`.
  - `load` har samma timeout på 15 s och samma felmappning som AVPlayerEngine.
  - `close()` stoppar spelaren och släpper media.
- [ ] **Step 4:** Kontrollera att CI blir grönt och att apparna fortfarande bygger, eftersom binärstorleken växer.
- [ ] **Step 5:** Commit: `feat(playback): VLCEngine via VLCKit`.

---

### Task 7: Appen – spelarvy, menyer, info-ruta och nästa avsnitt

**Files:**
- Create: `Apps/Shared/Player/*.swift` (se filstrukturen)
- Modify: `Apps/project.yml` (beroenden på IPTVPlayback: Playback och VLCEngine. På iOS: `UIBackgroundModes: audio`, för bild-i-bild)
- Modify: `Apps/Shared/Localizable.xcstrings` (nya nycklar på sv och en)
- Test: `Apps/SharedTests/PlayerScreenModelTests.swift`

**Interfaces:**
- Consumes: `PlaybackSession`, `PlaybackRequest` (Task 5), `AVPlayerEngine.player` (Task 4), `VLCPlayerEngine.drawable` (Task 6), `PlaybackSettings`, `NextEpisode` (Task 3) samt `LibraryStore.episodes` och `locator` (Task 2).
- Produces:
  - `struct PlayerScreen: View`, med `init(request: PlaybackRequest, playlistID: UUID, nextEpisodeProvider: (() async -> PlaybackRequest?)?)`. Den presenteras i helskärm.
  - `@MainActor @Observable final class PlayerScreenModel`:
    - `init(session: PlaybackSession, nextEpisodeProvider:)`
    - `var countdown: Int?`
    - `func startNextEpisodeCountdown()`
    - `func cancelCountdown()`
    - `var infoSummary: String`, till exempel `"2160p · Dolby Vision · Atmos · AVPlayer"`, som slår ihop `VideoInfo.summary` med motorns namn.
  - Värdvyer:
    - `AVPlayerHost` är en `UIViewControllerRepresentable` som omsluter `AVPlayerViewController`.
      - tvOS: `transportBarCustomMenuItems` med menyerna "Ljud", "Undertexter", "Spelare" (Apple/VLC) och "Info".
      - iOS: samma menyer i en egen meny-knapp, plus bild-i-bild och AirPlay från systemet.
    - `VLCPlayerHost` är en `UIViewRepresentable` för `drawable`, med `PlayerControlsOverlay` i SwiftUI.
      - Overlayen har play/paus, en skrubbningslist och samma fyra menyer.
      - tvOS: `.onPlayPauseCommand`, `.onMoveCommand` (vänster/höger = ±10 s), svep på Siri-fjärrkontrollen = skrubbning, och `.onExitCommand` stänger.
    - `NextEpisodeOverlay`: knappen "Nästa avsnitt" med 10 sekunders nedräkning. "Avbryt" stoppar nedräkningen, och när den når 0 startar nästa avsnitt.
  - Värdvyn anropar `session.tick()` en gång i sekunden. `scenePhase` `.background` eller `.inactive` ger `pauseAndSave()`, och när vyn försvinner anropas `stop()`.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@MainActor @Test func countdownStartsNextEpisodeAtZero() async { /* injicerad tidsstegare: 10 steg → nextEpisodeProvider anropad och ny session startad */ }
@MainActor @Test func cancelStopsCountdown() async { /* cancel efter 3 steg → ingen ny session */ }
@MainActor @Test func infoSummaryIncludesEngine() { /* FakeEngine-videoinfo 2160p DV + kind .vlc → "2160p · Dolby Vision · VLC" */ }
@MainActor @Test func errorKeysAreLocalized() { /* alla tre nycklarna playback.error.* finns i Bundle.main på både sv och en */ }
```

- [ ] **Step 2:** Pusha och kontrollera i CI. Förväntat resultat: FAIL.
- [ ] **Step 3:** Implementera. Vid motorbyte under uppspelning byts värdvyn ut och positionen behålls, vilket sessionen sköter. Inga egna stilar utöver vad systemet ger. Designen kommer i fas 3.
- [ ] **Step 4:** Kontrollera att CI blir grönt: iOS-testerna går igenom och tvOS bygger.
- [ ] **Step 5:** Commit: `feat(app): spelarvy med motorbyte, ljud/text-menyer, info och nästa avsnitt`.

---

### Task 8: Appen – detaljvyer, Fortsätt titta, live-uppspelning, inställningar och Keychain-städning

**Files:**
- Create: `Apps/Shared/Detail/MovieDetailView.swift`, `SeriesDetailView.swift`, `Apps/Shared/ContinueWatchingRow.swift`, `Apps/Shared/Settings/SettingsView.swift`, `EngineComparisonView.swift`, `FormatOverviewView.swift`
- Modify: `Apps/Shared/AppModel.swift`, `LibraryBrowserView.swift`, `PlaylistsView.swift`, `Localizable.xcstrings`
- Test: `Apps/SharedTests/AppModelPlaybackTests.swift`

**Interfaces:**
- Consumes: Task 2 (`movie`, `series`, `episodes`, `upsertEpisodes`, `locator`, `accountInfo`, `allPlaylistIDs`), Task 3 (`UserStateStore`, `PlaybackSettings`, `ProgressPolicy`, `NextEpisode`, `PlaylistStats` från fas 1) och Task 7 (`PlayerScreen`).
- Produces (i `AppModel`):
  - `let userState: UserStateStore`, som är en `UserDefaultsUserStateStore` i produktion.
  - `var settings: PlaybackSettings`, som sparas vid varje ändring.
  - `func episodes(for seriesProviderID: String, playlistID: UUID) async throws -> [Episode]`. Den läser från databasen. Är listan tom och spellistan är Xtream hämtas avsnitten via `XtreamClient.episodes(seriesID:)` och sparas med `upsertEpisodes`.
  - `func playbackRequest(kind: ContentKind, providerID: String, seriesProviderID: String?, playlistID: UUID) async throws -> PlaybackRequest`. Den slår upp locator och container och tar `startAt` från `ProgressPolicy.resumePosition`.
  - `func liveRequest(group: ChannelGroup, playlistID: UUID, displaySupportsHDR: Bool) -> PlaybackRequest`, där `isLive` är true och det inte finns någon `startAt`.
  - `func continueWatching(playlistID: UUID) async -> [ContinueWatchingItem]`. Posterna kopplas till titlar i databasen, och poster vars titel inte längre finns hoppas över.
  - Vid `load()`: Keychain-poster från `credentials.allPlaylistIDs()` som saknas i metadata raderas.
  - Vid `remove`: `userState.remove(playlistID:)` anropas också.

**Vyer:**
- `MovieDetailView`: titel, år, kvalitetsmärken utifrån container, knappen "Spela" eller "Fortsätt (mm:ss kvar)" och "Från början".
- `SeriesDetailView`: säsongsväljare och avsnittslista med förloppsindikator och sett-markering. Knappen "Fortsätt S1:E4" utgår från `lastWatchedEpisode`, eller nästa avsnitt om det senaste är sett.
- `LibraryBrowserView`: när man väljer en titel öppnas detaljvyn. I Live-fliken startar ett val `PlayerScreen` med den bästa varianten.
- `PlaylistsView`: under varje spellista visas utgångsdatum och "Max N anslutningar" när informationen finns. En rad "Fortsätt titta" ligger överst i spellistans bläddringsvy.
- `SettingsView`:
  - Standardspelare (Automatiskt, Apple eller VLC).
  - Ljudspråk i prioritetsordning, med lägg till, ta bort och flytta i en lista över vanliga språk.
  - Textläge och textspråk, samt "Föredra Atmos/surround".
  - Länk till `EngineComparisonView`, som visar tabellen i spec §7.1 på sv och en.
  - Länk till `FormatOverviewView`, som visar `PlaylistStats` per spellista.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@MainActor @Test func xtreamEpisodesFetchedLazilyAndCached() async throws { /* tom DB → episodes() anropar stubbens get_series_info en gång; andra anropet ger ingen ny request */ }
@MainActor @Test func playbackRequestUsesResume() async throws { /* sparad 600/6000 → request.startAt == 600 */ }
@MainActor @Test func continueWatchingSkipsVanishedTitles() async { /* progress för film "x" som inte finns i DB → utelämnas */ }
@MainActor @Test func orphanKeychainEntriesSweptOnLoad() async { /* creds har id A (i metadata) och B (inte i metadata) → efter load finns bara A */ }
@MainActor @Test func removeClearsUserState() async { /* remove(id) → continueWatching tomt */ }
@MainActor @Test func liveRequestPrefersBestVariant() { /* grupp med HD/FHD/4K HDR, HDR-skärm → 4K-locator, isLive */ }
@MainActor @Test func settingsPersist() { /* ändra motor → ny AppModel med samma defaults → samma värde */ }
```

- [ ] **Step 2:** Pusha och kontrollera i CI. Förväntat resultat: FAIL.
- [ ] **Step 3:** Implementera enligt Interfaces och Vyer.
- [ ] **Step 4:** Kontrollera att CI blir grönt.
- [ ] **Step 5:** Commit: `feat(app): detaljvyer, fortsätt titta, live-uppspelning, inställningar och Keychain-städning`.

---

### Task 9: Fasavslut – README och testlista för enheten

**Files:**
- Modify: `README.md`

- [ ] **Step 1:** Lägg till följande i README:
  - Avsnittet "Licenser" med VLCKit (LGPL-2.1) och GRDB (MIT).
  - Avsnittet "Testlista fas 2 (riktig Apple TV)", med punkterna:
    1. En film i .mp4/.m3u8 spelas i Apples spelare, och info-rutan visar motorn.
    2. En .mkv-film spelas automatiskt i VLC.
    3. Byt motor mitt i en film. Positionen och språket ska följa med.
    4. Ljud- och textmenyerna fungerar, och svenska väljs automatiskt enligt inställningarna.
    5. 4K Dolby Vision-innehåll: med "Matcha innehåll" påslaget byter TV:n till Dolby Vision, och info-rutan visar "Dolby Vision".
    6. Atmos: receivern eller TV:n visar Atmos.
    7. Stäng mitt i en film, öppna igen och välj "Fortsätt". Filmen fortsätter där du var.
    8. Seriens sista 30 sekunder: "Nästa avsnitt" räknar ner och startar.
    9. Live-kanal: bästa kvaliteten väljs, och kanalbytet tar under 2 s.
    10. Siri-fjärrkontrollen: svep för att skrubba, och play/paus fungerar i båda motorerna.
    11. Inställningar → "Spelarna": jämförelsetabellen visas.
- [ ] **Step 2:** Kör `gitleaks detect --config .gitleaks.toml`, som ska ge `no leaks found`. Kontrollera att CI är grönt.
- [ ] **Step 3:** Commit: `docs: licenser och testlista för fas 2`.
