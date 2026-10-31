# Fas 5: OpenSubtitles – implementationsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Användaren kan söka och ladda ner undertexter från OpenSubtitles i spelaren och på detaljsidan, se dem renderade i både AVPlayer och VLC, justera synken i steg om 0,1 s och få dem sparade per titel och profil.

**Architecture:** Ny ren modul `Subtitles` i `IPTVKit` (SRT/WebVTT-tolk med teckenkodsavkodning, snabb cue-uppslagning med synkförskjutning, OpenSubtitles-klient). Lagring och orkestrering (`SubtitleStore`, `SubtitleService`, Keychain-uppgifter) hamnar i `IPTVPlatform`. Spelarmotorerna får `addExternalSubtitle`: VLC via `addPlaybackSlave`, AVPlayer via en egen SwiftUI-överlagring som läser cues från en periodisk tid. UI: sökblad i spelarmenyn, inställningar för konto och utseende, och info-rutan på detaljsidan.

**Tech Stack:** Swift 6, SwiftUI, GRDB, `URLSession` via `HTTPClient`, Keychain, AVFoundation, VLCKit.

**Spec:** `docs/superpowers/specs/2026-10-25-iptv-app-design.md` (§3 hemligheter, §6.3 info-ruta, §7.1 motorer, §7.2 ljud och undertexter, §10 profiler). Fas 4-planen (`2026-10-31-fas4-live-tv-epg.md`) beskriver hur `PlayerScreenModel`, `switchChannel` och menyerna fungerar. De återanvänds här.

## Global Constraints

- Swift 6 strikt samtidighet; `@Observable`/`@MainActor` i UI; Swift Testing för tester.
- **Inga hemligheter i repot, loggar, fel, signposts, fixtures eller commit.** OpenSubtitles API-nyckel kommer från `OPENSUBTITLES_API_KEY` (`Secrets.xcconfig` lokalt, GitHub Secrets i CI) och användarens inloggning lagras **bara i Keychain** (§3). Fel och loggtexter får aldrig innehålla nyckel, användarnamn, lösenord eller token.
- Endast gratisnivå [Beslutat]: cache, backoff och snygg degradering vid rate limit eller slut dagskvot. Ingen nyckel eller ingen inloggning stänger funktionen med ett tydligt meddelande, aldrig krasch.
- OpenSubtitles kräver `Api-Key`, ett eget `User-Agent` ("IPTVApp v1.0") och `Content-Type: application/json`. Nedladdning kräver en inloggad användartoken. Token hålls bara i minnet (giltig ca 24 h) och förnyas med ny inloggning vid 401.
- **Externa undertexter** [§7.2]: AVPlayer renderar via egen överlagring (SRT/VTT tolkas och synkas via periodisk tidsobservatör); VLC använder `addPlaybackSlave`. **Synkjustering ± i steg om 0,1 s sparas per titel.** Nedladdade undertexter sparas per titel och profil.
- **Per profil** [§7.2]: förvalt textspråk och textutseende (storlek, färg, bakgrund). Barnprofil [§10] får aldrig söka eller ladda ner (inget externt anrop, inget konto).
- Ingen nätverksåtkomst, filläsning eller databasskrivning på huvudtråden (§9). Inget dyrt i `body`.
- Svenska i commit-meddelanden; trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Nya UI-strängar i `Localizable.xcstrings` (engelska nycklar, svensk översättning).
- Apple-kod och Library/app-tester verifieras bara i CI (eller på Macen när den används); `IPTVKit` testas lokalt med `source scripts/swift-env.sh && cd Packages/IPTVKit && swift test`. **Per-fil-import-revision** före varje commit av Apple-kod (CI har upprepade gånger fångat saknade `import Core/Providers/PlaybackCore`; `Library.LibraryItem` ska kvalificeras).
- Subagenter: bara `model: sonnet`; Opus bara efter verklig fastkörning, noterat i ledgern.

## Beslut jag tagit (Mitt beslut)

- **Sökning:** på TMDB-id (och IMDb-id om det finns) plus säsong/avsnitt, i andra hand på titelfråga (titel + år). **Filhash (`moviehash`) skjuts upp**: det kräver Range-läsning av strömmen och belastar `max_connections`, och specen nämner det bara som sista utväg.
- **Format:** SRT och WebVTT tolkas av appen. ASS/PGS och andra format visas bara om motorn själv klarar dem (VLC).
- **Info-rutan på detaljsidan** visar uppgifter som sparades vid senaste uppspelning av titeln (ljud- och textspår, video, spelare) samt nedladdade undertexter, med knappen "Sök undertexter". Specen vill ha spåren redan före uppspelning, men de finns först när motorn laddat strömmen.
- **Utseende** gäller appens egen överlagring och, så långt VLC tillåter, VLC. AVPlayers inbyggda text följer systemets inställning.

## Review Focus

1. **Teckenkodning:** svenska SRT-filer är ofta Windows-1252/ISO-8859-1 (å ä ö), ibland UTF-16 eller UTF-8 med BOM. Texten ska visas rätt, inte som "Ã¥". Task 1.
2. **Trasiga SRT/VTT:** saknat radnummer, `\r\n`, tid med punkt i stället för komma, överlappande cues, tomma rader inne i en cue, HTML-taggar (`<i>`, `<b>`, `<font>`), VTT med cue-inställningar, `NOTE` och `STYLE`. Inget får krascha och rimlig text ska visas. Task 1.
3. **Hemligheter:** API-nyckel, användarnamn, lösenord och token i fel, loggar, signposts och tester. Task 2, 3, 5.
4. **Slut dagskvot, 429, 401, ej inloggad, ingen nyckel:** tydligt meddelande, ingen återförsöksstorm, ingen krasch. Task 2, 3, 6.
5. **Barnprofil:** ingen sökning eller nedladdning via något flöde (spelarmeny, detaljsida, inställningar). Task 5, 6, 7.
6. **Synkförskjutning:** ± 0,1 s sparas per titel, negativ tid och stora värden klampas, överlevande vid motorbyte. Task 1, 4, 6.
7. **Motorbyte mitt i en uppspelning** (AVPlayer ↔ VLC) behåller vald extern undertext (§7.1). Task 4.
8. **Många träffar och fel språk:** sortering (förvalda språk först, sedan betyg och nedladdningar), bara första sidan hämtas, tomt resultat visas vänligt. Task 3, 6.

---

## File Structure

| Fil | Ansvar |
|---|---|
| `Packages/IPTVKit/Package.swift` | ny target `Subtitles` + test-target |
| `Packages/IPTVKit/Sources/Subtitles/SubtitleDecoder.swift` (ny) | byte → text (BOM, UTF-8, UTF-16, Windows-1252-reserv) |
| `Packages/IPTVKit/Sources/Subtitles/SubtitleParser.swift` (ny) | SRT/VTT → `[SubtitleCue]` |
| `Packages/IPTVKit/Sources/Subtitles/SubtitleTrack.swift` (ny) | cue-uppslag med förskjutning |
| `Packages/IPTVKit/Sources/Subtitles/OpenSubtitlesClient.swift` (ny) | REST-klient, modeller, felmappning |
| `Packages/IPTVKit/Sources/Providers/HTTPClient.swift` | `post(_:headers:body:)` |
| `Packages/IPTVKit/Sources/PlaybackCore/Settings.swift` | `SubtitleAppearance` i `PlaybackSettings` |
| `Packages/IPTVPlatform/Sources/Secrets/KeychainOpenSubtitlesStore.swift` (ny) | användarnamn/lösenord i Keychain |
| `Packages/IPTVPlatform/Sources/Library/AppDatabase.swift` | migrering `v7` |
| `Packages/IPTVPlatform/Sources/Library/SubtitleStore.swift` (ny) | filer, index, förskjutning, tekniska uppgifter |
| `Packages/IPTVPlatform/Sources/Library/SubtitleService.swift` (ny) | sök, sortera, ladda ner, spara, kvot |
| `Packages/IPTVPlayback/Sources/Playback/PlayerEngine.swift`, `AVPlayerEngine.swift`, `VLCPlayerEngine.swift`, `PlaybackSession.swift`, `FakeEngine.swift` | externa undertexter |
| `Apps/Shared/AppModel+Subtitles.swift` (ny) | AppModel-API med barnspärr |
| `Apps/Shared/Settings/OpenSubtitlesSettingsView.swift` (ny), `SubtitleAppearanceView.swift` (ny) | konto och utseende |
| `Apps/Shared/Player/SubtitleSearchSheet.swift` (ny), `ExternalSubtitleOverlay.swift` (ny), `PlayerMenus.swift`, `PlayerScreenModel.swift` | sökblad, överlagring, synkjustering |
| `Apps/Shared/Detail/TitleInfoBox.swift` (ny) | info-ruta på detaljsidan |
| `Apps/Config/*` | `OPENSUBTITLES_API_KEY` |

---

### Task 1: Undertextmodul – avkodning, tolk och cue-uppslag

**Files:**
- Modify: `Packages/IPTVKit/Package.swift` (target `Subtitles`, test-target `SubtitlesTests`)
- Create: `Packages/IPTVKit/Sources/Subtitles/SubtitleDecoder.swift`, `SubtitleParser.swift`, `SubtitleTrack.swift`
- Create fixtures: `Packages/IPTVKit/Tests/SubtitlesTests/Fixtures/` (syntetiska `sample-sv-cp1252.srt`, `sample-utf8-bom.srt`, `sample-utf16le.srt`, `sample-messy.srt`, `sample.vtt`; ingen riktig upphovsrättsskyddad text)
- Test: `Packages/IPTVKit/Tests/SubtitlesTests/SubtitleDecoderTests.swift`, `SubtitleParserTests.swift`, `SubtitleTrackTests.swift`

**Interfaces:**
- Consumes: —
- Produces:
  ```swift
  public struct SubtitleCue: Sendable, Hashable { public var start: Double; public var end: Double; public var text: String }   // sekunder
  public enum SubtitleDecoder { public static func decode(_ data: Data) -> String }          // aldrig kast; UTF-8 BOM/UTF-16 BOM → UTF-8 → Windows-1252
  public enum SubtitleFormat: Sendable { case srt, vtt }
  public enum SubtitleParser {
      public static func detectFormat(_ text: String) -> SubtitleFormat
      public static func parse(_ text: String) -> [SubtitleCue]                              // sorterad på start; taggar strippade; tom text släpps
  }
  public struct SubtitleTrack: Sendable {
      public init(cues: [SubtitleCue])
      public func cue(at time: Double, offset: Double) -> SubtitleCue?                       // tid + offset; binärsökning
      public static func clampOffset(_ offset: Double) -> Double                             // −600…+600 s, avrundat till 0,1 s
  }
  ```

- [ ] **Step 1: Write failing tests:**
  - `decodesCp1252SwedishLetters` (å ä ö Å Ä Ö i filen ger rätt tecken), `decodesUtf8WithBOM`, `decodesUtf16LEAndBE`, `invalidUtf8FallsBackToCp1252`, `emptyDataGivesEmptyString`.
  - `parsesBasicSrt`, `parsesDotInsteadOfCommaInTimestamp`, `parsesWithoutIndexLines`, `handlesCRLF`, `keepsMultilineCueText`, `stripsHtmlAndFontTags`, `dropsEmptyCues`, `toleratesOverlappingCuesAndSortsByStart`, `blankLineInsideCueDoesNotCrash`.
  - `parsesVttWithHeaderAndCueSettings` (ignorerar `WEBVTT`-huvud, `NOTE`, `STYLE`, `align:` m.m.; tid utan timmar `01:02.500`), `detectsFormatFromHeader`.
  - `cueAtFindsActiveCue`, `cueAtRespectsPositiveAndNegativeOffset`, `cueAtOutsideAnyCueIsNil`, `clampOffsetLimitsAndRoundsToTenths`.
- [ ] **Step 2: Run:** `swift test --filter SubtitlesTests` → FAIL (moduler saknas).
- [ ] **Step 3: Implement** de tre filerna. Avkodning utan beroenden som saknas på Linux/Windows: kontrollera BOM-bytes för hand, `String(data:encoding: .utf8)` och en egen Windows-1252-tabell (0x80–0x9F) som reserv. Tolken delar på blankrad men hanterar att en cue-text kan sakna sluttom rad; tider tolkas för hand (ingen `DateFormatter`).
- [ ] **Step 4: Run** `swift test` → PASS (hela sviten).
- [ ] **Step 5: Commit** `feat(subtitles): SRT/VTT-tolk med teckenkodsavkodning och cue-uppslag`.

---

### Task 2: OpenSubtitles-klient

**Files:**
- Modify: `Packages/IPTVKit/Sources/Providers/HTTPClient.swift` (`post`)
- Create: `Packages/IPTVKit/Sources/Subtitles/OpenSubtitlesClient.swift`
- Create fixtures: `Packages/IPTVKit/Tests/SubtitlesTests/Fixtures/os-login.json`, `os-search.json`, `os-download.json`, `os-user.json` (syntetiska, påhittade id:n och användare)
- Test: `Packages/IPTVKit/Tests/SubtitlesTests/OpenSubtitlesClientTests.swift`

**Interfaces:**
- Consumes: `HTTPClient` (Providers), `LanguageCode` (PlaybackCore).
- Produces:
  ```swift
  // HTTPClient (nytt krav med standardimplementation som kastar ProviderError.invalidResponse)
  func post(_ url: URL, headers: [String: String], body: Data) async throws -> (Data, Int, [String: String])
  public struct OpenSubtitlesQuery: Sendable, Equatable {
      public var tmdbID: Int?; public var imdbID: String?; public var season: Int?; public var episode: Int?
      public var title: String?; public var year: Int?; public var languages: [String]
  }
  public struct OpenSubtitlesResult: Sendable, Hashable, Identifiable {
      public var id: Int            // file_id
      public var language: String; public var release: String; public var fileName: String
      public var rating: Double; public var downloadCount: Int; public var hearingImpaired: Bool; public var aiTranslated: Bool
  }
  public struct OpenSubtitlesQuota: Sendable, Equatable { public var remaining: Int?; public var allowed: Int?; public var resetAt: Date? }
  public enum OpenSubtitlesError: Error, Sendable, Equatable { case noAPIKey, notLoggedIn, invalidCredentials, quotaExhausted(resetAt: Date?), rateLimited(retryAfter: TimeInterval?), network, badResponse }
  public final class OpenSubtitlesClient: @unchecked Sendable {   // eller actor; samma publika yta
      public init(apiKey: String?, http: HTTPClient, now: @Sendable @escaping () -> Date = Date.init)
      public func login(username: String, password: String) async throws -> OpenSubtitlesQuota
      public func logout()                                   // glömmer token i minnet
      public var isLoggedIn: Bool { get }
      public func search(_ query: OpenSubtitlesQuery) async throws -> [OpenSubtitlesResult]   // första sidan, cache 10 min per fråga
      public func download(fileID: Int) async throws -> (data: Data, quota: OpenSubtitlesQuota)
      public func quota() async throws -> OpenSubtitlesQuota
  }
  ```
  Bas-URL `https://api.opensubtitles.com/api/v1` (inloggningssvaret kan ange en annan värd som ska användas). Alla fel är fasta värden utan text från servern eller URL.

- [ ] **Step 1: Write failing tests** med en mock-`HTTPClient` som spelar in begäranden: `searchBuildsQueryFromTmdbSeasonEpisode` (rätt query-parametrar, språk som kommaseparerad lista, nyckel och `User-Agent` i headers); `searchFallsBackToTitleQuery` när id saknas; `searchParsesFixtureAndMapsFields`; `searchIsCachedForTenMinutes` (klocka injiceras; andra anropet träffar inte nätet); `searchWithoutAPIKeyThrowsNoAPIKey`; `downloadRequiresLogin` → `.notLoggedIn`; `loginStoresTokenAndUsesItForDownload`; `unauthorizedRefreshesTokenOnce` (401 → ny inloggning med sparade uppgifter är **inte** klientens jobb: kasta `.notLoggedIn` och glöm token); `downloadFollowsLinkAndReturnsBytes`; `quotaExhaustedOnHttp406` (inkl. `resetAt` från svaret); `rateLimitedOnHttp429ReadsRetryAfter`; `errorsNeverContainCredentialsOrKey` (förstör `String(describing:)` av varje fel och kontrollera att nyckel/användare/lösenord/token saknas).
- [ ] **Step 2: Run:** `swift test --filter OpenSubtitlesClientTests` → FAIL.
- [ ] **Step 3: Implement** klienten. JSON via `Codable`-DTO:er med `decodeIfPresent` (API:t är inkonsekvent); `Retry-After` som sekunder; token och nyckel finns bara som privata fält utan `CustomStringConvertible`-läckage (följ mönstret i `PlaylistSecret`). Nedladdning: `POST /download {file_id}` ger en `link`, som hämtas med `get`.
- [ ] **Step 4: Run** `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(subtitles): OpenSubtitles-klient med kvot, cache och felmappning`.

---

### Task 3: Lagring, Keychain och `SubtitleService`

**Files:**
- Modify: `Packages/IPTVPlatform/Sources/Library/AppDatabase.swift` (migrering `v7`), `Packages/IPTVPlatform/Tests/LibraryTests/MigrationTests.swift`
- Create: `Packages/IPTVPlatform/Sources/Secrets/KeychainOpenSubtitlesStore.swift`, `Packages/IPTVPlatform/Sources/Library/SubtitleStore.swift`, `SubtitleService.swift`
- Test: `Packages/IPTVPlatform/Tests/LibraryTests/SubtitleStoreTests.swift`, `SubtitleServiceTests.swift`; `Packages/IPTVPlatform/Tests/SecretsTests/` (följ befintligt mönster för Keychain-tester)

**Interfaces:**
- Consumes: `OpenSubtitlesClient`/`Query`/`Result`/`Quota`/`Error` (Task 2), `SubtitleDecoder`/`Parser` (Task 1), `AppDatabase`-mönstret, `CredentialStore`-stilen i `KeychainCredentialStore`.
- Produces:
  ```swift
  public struct OpenSubtitlesCredentials: Sendable { public var username: String; public var password: String }   // ingen description/mirror
  public protocol OpenSubtitlesCredentialStore: Sendable { func load() throws -> OpenSubtitlesCredentials?; func save(_:) throws; func clear() throws }
  public final class KeychainOpenSubtitlesStore: OpenSubtitlesCredentialStore   // egen Keychain-service, som KeychainProfilePinStore
  public struct SubtitleKey: Sendable, Hashable { public var profileID: UUID; public var playlistID: UUID; public var kind: ContentKind; public var providerID: String }
  public struct StoredSubtitle: Sendable, Hashable, Identifiable { public var id: Int /*file_id*/; public var language: String; public var release: String; public var addedAt: Date; public var fileURL: URL }
  public final class SubtitleStore: Sendable {
      public init(db: AppDatabase, directory: URL)       // filer under <directory>/<profile>/<playlist>/<kind>-<providerID>/<fileID>.srt (alltid UTF-8)
      public func save(_ data: Data, result: OpenSubtitlesResult, for key: SubtitleKey) throws -> StoredSubtitle    // avkodar → UTF-8, ersätter samma fileID
      public func list(for key: SubtitleKey) throws -> [StoredSubtitle]
      public func remove(fileID: Int, for key: SubtitleKey) throws
      public func offset(for key: SubtitleKey) throws -> Double
      public func setOffset(_ seconds: Double, for key: SubtitleKey) throws     // klampas via SubtitleTrack.clampOffset
      public func recordTechInfo(_ info: TitleTechInfo, for key: SubtitleKey) throws     // för detaljsidans info-ruta (Task 7)
      public func techInfo(for key: SubtitleKey) throws -> TitleTechInfo?
  }
  public struct TitleTechInfo: Sendable, Codable, Hashable { public var audioLanguages: [String]; public var subtitleLanguages: [String]; public var videoSummary: String?; public var engine: String?; public var recordedAt: Date }
  public final class SubtitleService: Sendable {
      public init(client: OpenSubtitlesClient, store: SubtitleStore, credentials: OpenSubtitlesCredentialStore)
      public func search(_ query: OpenSubtitlesQuery, preferredLanguages: [String]) async throws -> [OpenSubtitlesResult]   // sorterad: förvalda språk först (i ordning), därefter betyg, därefter nedladdningar
      public func download(_ result: OpenSubtitlesResult, for key: SubtitleKey) async throws -> (StoredSubtitle, OpenSubtitlesQuota)   // loggar in med sparade uppgifter vid behov
      public func login(username: String, password: String) async throws -> OpenSubtitlesQuota   // sparar bara i Keychain om inloggningen lyckades
      public func logout() throws
      public func quota() async throws -> OpenSubtitlesQuota
  }
  ```
  Tabeller (v7, `ON DELETE CASCADE` mot `playlist`): `subtitleFile(profileID, playlistID, kind, providerID, fileID, language, release, addedAt, path, PRIMARY KEY(profileID, playlistID, kind, providerID, fileID))`, `subtitleOffset(profileID, playlistID, kind, providerID, offsetMs, PRIMARY KEY(...))`, `titleTechInfo(profileID, playlistID, kind, providerID, json, PRIMARY KEY(...))`. Sökvägar sparas relativt `directory` (appens container-sökväg ändras mellan installationer).

- [ ] **Step 1: Write failing tests:** `saveConvertsCp1252ToUtf8File`, `saveReplacesSameFileID`, `listIsPerProfileAndTitle` (annan profil/titel ser inget), `removeDeletesRowAndFile`, `offsetRoundTripsAndClamps`, `techInfoRoundTrips`, `removingPlaylistCascades` (rader borta; filer städas via `purgeOrphans()` som du lägger till och testar), `searchSortsPreferredLanguagesThenRatingThenDownloads`, `downloadLogsInWithStoredCredentialsWhenNeeded` (mock-klient), `loginSavesCredentialsOnlyOnSuccess`, `logoutClearsKeychainAndToken`, `downloadWithoutCredentialsThrowsNotLoggedIn`, och ett läckagetest: inget fel från servicen innehåller användarnamn/lösenord.
- [ ] **Step 2: Run** (CI/Mac) → FAIL.
- [ ] **Step 3: Implement** enligt gränssnitten; filskrivning atomärt (`.atomic`); inga `try?` som sväljer skrivfel.
- [ ] **Step 4:** Verifiera i CI (`apple`-jobbet grönt, `MigrationTests` väntar `v1…v7`).
- [ ] **Step 5: Commit** `feat(library): undertextlagring, Keychain-uppgifter och SubtitleService (migrering v7)`.

---

### Task 4: Motorstöd för externa undertexter och synk

**Files:**
- Modify: `Packages/IPTVPlayback/Sources/Playback/PlayerEngine.swift`, `AVPlayerEngine.swift`, `PlaybackSession.swift`, `Packages/IPTVPlayback/Sources/VLCEngine/VLCPlayerEngine.swift`, `Packages/IPTVPlayback/Sources/PlaybackTestSupport/FakeEngine.swift`
- Modify: `Packages/IPTVKit/Sources/PlaybackCore/Tracks.swift` (extern spårmarkering)
- Test: `Packages/IPTVPlayback/Tests/PlaybackTests/ExternalSubtitleTests.swift` (CI), `Packages/IPTVKit/Tests/PlaybackCoreTests/ExternalTrackTests.swift` (lokalt)

**Interfaces:**
- Consumes: `SubtitleTrack`, `SubtitleParser`, `SubtitleDecoder` (Task 1), `StoredSubtitle` (Task 3).
- Produces:
  ```swift
  // PlaybackCore/Tracks.swift
  public extension MediaTrack { static func externalID(fileID: Int) -> String; var isExternal: Bool { get } }   // id "ext:<fileID>"
  // PlayerEngine (nytt krav; standard: kastar .unsupported)
  func addExternalSubtitle(fileURL: URL, language: String?, title: String, fileID: Int) async throws
  var externalCueProvider: ((Double) -> SubtitleCue?)? { get }   // AVPlayer: cue för vald extern text vid given tid, annars nil; VLC: nil (VLC ritar själv)
  func setSubtitleOffset(_ seconds: Double)                       // AVPlayer: lagras för cue-uppslag; VLC: `currentVideoSubTitleDelay` (mikrosekunder)
  // PlaybackSession
  public func attachExternalSubtitles(_ subs: [StoredSubtitle], offset: Double) async     // kallas efter att motorn laddat; lägger till och väljer enligt TrackSelector
  ```
  Externa spår syns i `subtitleTracks` med `id = "ext:<fileID>"`, `isForced=false`, språk och titel ur releasenamnet. `select(subtitleID:)` med ett externt id aktiverar det (AVPlayer: stänger av inbyggd text och slår på överlagringen; VLC: väljer slave-spåret). Vid motorbyte (`switchEngine`/`reload`) läggs externa undertexter och förskjutning till igen på den nya motorn och **vald extern text behålls** (§7.1).

- [ ] **Step 1: Write failing tests** (`FakeEngine`): `externalTrackAppearsInSubtitleTracksWithExtId`, `selectingExternalEnablesCueProvider`, `selectingEmbeddedDisablesExternal`, `offsetShiftsCueLookup` (±0,1 s), `engineSwitchReattachesExternalAndKeepsSelection`, `attachSkipsMissingFilesWithoutFailing`, `unsupportedEngineThrowsUnsupported` (standardimplementation), `offsetClampedToLimits`; lokalt: `externalIDRoundTrips`, `isExternalOnlyForExtPrefix`.
- [ ] **Step 2: Run** `swift test --filter ExternalTrackTests` (lokalt) → FAIL; Playback-testerna i CI.
- [ ] **Step 3: Implement.** AVPlayer: `addExternalSubtitle` läser filen (utanför huvudtråden), avkodar och tolkar, bygger en `SubtitleTrack` och lägger spåret i listan. Ingen `AVMediaSelection`-hack. VLC: `addPlaybackSlave(url, type: .subtitle, enforce: false)`; hitta det nya spåret genom att jämföra spårlistan före/efter (VLC lägger till asynkront: vänta begränsat), mappa till `ext:<fileID>`. `PlaybackSession.attachExternalSubtitles` körs i `didLoad` efter `applyPreferredTracks`, och på nytt efter motorbyte.
- [ ] **Step 4:** Lokala tester gröna, resten i CI.
- [ ] **Step 5: Commit** `feat(playback): externa undertexter med synkförskjutning i AVPlayer och VLC`.

---

### Task 5: AppModel, nyckelhantering, inställningar för konto och utseende

**Files:**
- Modify: `Apps/Config/Base.xcconfig`, `Apps/Config/Secrets.xcconfig.template`, `Apps/Config/AppInfo.plist`, `Apps/Config/iOSAppInfo.plist` (`OPENSUBTITLES_API_KEY`, samma mönster som `TMDB_READ_TOKEN`), `README.md` (avsnitt "Nycklar": OpenSubtitles), `Packages/IPTVKit/Sources/PlaybackCore/Settings.swift` (`SubtitleAppearance`)
- Create: `Apps/Shared/AppModel+Subtitles.swift`, `Apps/Shared/Settings/OpenSubtitlesSettingsView.swift`, `Apps/Shared/Settings/SubtitleAppearanceView.swift`
- Modify: `Apps/Shared/AppModel.swift` (konstruera `SubtitleStore`/`SubtitleService`/`OpenSubtitlesClient`, injicerbart för tester), `Apps/Shared/Settings/SettingsView.swift`, `Apps/Shared/Localizable.xcstrings`
- Test: `Packages/IPTVKit/Tests/PlaybackCoreTests/SubtitleAppearanceTests.swift` (lokalt), `Apps/SharedTests/SubtitleModelTests.swift` (CI)

**Interfaces:**
- Consumes: `SubtitleService`, `SubtitleStore`, `OpenSubtitlesCredentialStore` (Task 3), `PlaybackSettings` per profil.
- Produces:
  ```swift
  // PlaybackCore
  public struct SubtitleAppearance: Codable, Equatable, Sendable { public enum Size: String, Codable, CaseIterable, Sendable { case small, medium, large, extraLarge }
      public enum Palette: String, Codable, CaseIterable, Sendable { case white, yellow, cyan }
      public enum Background: String, Codable, CaseIterable, Sendable { case none, shadow, box }
      public var size: Size; public var palette: Palette; public var background: Background }   // standard: .medium, .white, .shadow
  // PlaybackSettings.subtitleAppearance: SubtitleAppearance  (decodeIfPresent; gamla blobbar avkodas)
  // AppModel+Subtitles – alla returnerar tomt/nil/kastar .notAllowed när kidsRestricted
  var subtitlesAvailable: Bool { get }                                     // nyckel finns och inte barnläge
  func subtitleKey(for request: PlaybackRequest, playlistID: UUID) -> SubtitleKey?
  func searchSubtitles(for request: PlaybackRequest, playlistID: UUID, languages: [String]) async throws -> [OpenSubtitlesResult]
  func downloadSubtitle(_ result: OpenSubtitlesResult, for request: PlaybackRequest, playlistID: UUID) async throws -> (StoredSubtitle, OpenSubtitlesQuota)
  func storedSubtitles(for request: PlaybackRequest, playlistID: UUID) async -> (subs: [StoredSubtitle], offset: Double)
  func setSubtitleOffset(_ seconds: Double, for request: PlaybackRequest, playlistID: UUID) async
  func openSubtitlesLogin(username: String, password: String) async throws -> OpenSubtitlesQuota
  func openSubtitlesLogout() throws;  func openSubtitlesQuota() async -> OpenSubtitlesQuota?;  var openSubtitlesLoggedIn: Bool { get }
  ```
  Frågan byggs av `TitleMetadata` (tmdbID, imdbID; för avsnitt serien och säsong/avsnitt ur `Episode`) via befintlig metadatatjänst; saknas metadata används titel + år. Nyckeln kommer ur `Bundle.main.infoDictionary` med samma regel som TMDB-token (tom eller oersatt `$(…)` = saknad). Inställningsvyn: användarnamn/lösenord (SecureField), inloggning visar återstående dagskvot, utloggning, tydlig status när nyckel saknas ("Funktionen är avstängd"). Utseende: tre val med förhandsvisning. Båda döljs för barnprofil.

- [ ] **Step 1: Write failing tests:** lokalt `appearanceDecodesFromOldSettingsBlob`, `appearanceDefaults`; CI: `kidsProfileGetsNoSearchNoDownloadNoLogin` (alla API:n tomma/`notAllowed`, ingen anrop mot en räknande mock), `noActiveProfileIsTreatedAsKids`, `queryUsesTmdbAndEpisodeNumbers`, `queryFallsBackToTitleYear`, `missingAPIKeyDisablesFeature`, `credentialsNeverInStateDescriptions`, `loginFailureKeepsLoggedOutAndKeychainEmpty`.
- [ ] **Step 2: Run** (lokalt/CI) → FAIL.
- [ ] **Step 3: Implement.** Per-fil-import-revision. Lägg `OPENSUBTITLES_API_KEY` i `Base.xcconfig` (tom), mallen och båda plist-filerna; kontrollera att CI-jobbet inte skriver ut den (följ hur TMDB hanteras).
- [ ] **Step 4:** Lokala tester gröna; CI grönt.
- [ ] **Step 5: Commit** `feat(app): OpenSubtitles-konto, nyckelhantering och textutseende i inställningar`.

---

### Task 6: Spelaren – sökblad, överlagring och synkjustering

**Files:**
- Create: `Apps/Shared/Player/SubtitleSearchSheet.swift`, `Apps/Shared/Player/ExternalSubtitleOverlay.swift`
- Modify: `Apps/Shared/Player/PlayerMenus.swift` ("Sök fler undertexter…" och synkpunkter), `Apps/Shared/Player/PlayerScreenModel.swift`, `Apps/Shared/Player/PlayerScreen.swift`, `Apps/Shared/Localizable.xcstrings`
- Test: `Apps/SharedTests/SubtitleSearchModelTests.swift`, `Apps/SharedTests/PlayerScreenModelSubtitleTests.swift`

**Interfaces:**
- Consumes: `AppModel+Subtitles` (Task 5), `PlaybackSession.attachExternalSubtitles`, `PlayerEngine.externalCueProvider`/`setSubtitleOffset` (Task 4), `SubtitleAppearance`.
- Produces:
  ```swift
  @MainActor @Observable final class SubtitleSearchModel {
      init(request: PlaybackRequest, playlistID: UUID, app: AppModel, preferredLanguages: [String], onDownloaded: @escaping @MainActor (StoredSubtitle) async -> Void)
      enum Phase: Equatable { case idle, searching, results([OpenSubtitlesResult]), empty, failed(SubtitleSearchFailure), downloading(Int), loginRequired }
      enum SubtitleSearchFailure: Equatable { case noKey, notAllowed, quota(resetAt: Date?), rateLimited, network }
      var phase: Phase { get }; var quota: OpenSubtitlesQuota? { get }
      func search() async; func download(_ result: OpenSubtitlesResult) async
  }
  // PlayerScreenModel
  func presentSubtitleSearch();  func adjustSubtitleOffset(by delta: Double) async     // ±0,1, sparas per titel via AppModel, tillämpas direkt på motorn
  var subtitleOffset: Double { get }
  ```
  Spelarmenyn får "Sök fler undertexter…" (bara när `subtitlesAvailable`, dvs. inte barnläge och nyckel finns) och, när en extern text är vald, "Synk: −0,1 s / +0,1 s / nollställ" med aktuellt värde. På tvOS visas sökbladet i samma Select-ark-mönster som Task 9 (live) och ett vanligt blad på iOS. Resultatlistan visar språk, release, betyg, nedladdningar, markerar hörselhjälp och AI-översatt, och visar återstående dagskvot. Efter nedladdning läggs texten till, väljs och används direkt. `ExternalSubtitleOverlay` ritar `externalCueProvider(currentTime)` i en `TimelineView(.periodic(from:by: 0.2))` ovanpå AVPlayer (inte över VLC), med `SubtitleAppearance`; inget arbete i `body` utöver en uppslagning. Vid uppspelningsstart hämtas titelns sparade undertexter och förskjutning och läggs till via `attachExternalSubtitles`.

- [ ] **Step 1: Write failing tests:** `searchSortsAndShowsResults`, `emptyResultShowsEmptyPhase`, `quotaExhaustedShowsQuotaFailureWithResetTime`, `notLoggedInShowsLoginRequired`, `rateLimitedDoesNotRetryAutomatically`, `downloadAppliesAndSelectsTrack`, `kidsProfileCannotPresentSearch` (menyposten saknas, `presentSubtitleSearch` gör inget), `offsetAdjustsInTenthsAndPersists`, `offsetSurvivesEngineSwitch`, `storedSubtitlesAttachedOnStart`, `overlayHiddenWhenNoExternalSelected`. Ren logik (fasövergångar, sortering) testas utan UI.
- [ ] **Step 2: Run** (CI/Mac) → FAIL.
- [ ] **Step 3: Implement.** Menyerna återanvänder `PlayerMenu`; tvOS-fokus: `.onExitCommand` stänger sökbladet, inte spelaren. Inga nätverksanrop i `body`; sökningen körs i en uppgift som avbryts när bladet stängs.
- [ ] **Step 4:** Verifiera i CI.
- [ ] **Step 5: Commit** `feat(player): sök och ladda ner undertexter, överlagring och synkjustering`.

---

### Task 7: Info-ruta på detaljsidan

**Files:**
- Create: `Apps/Shared/Detail/TitleInfoBox.swift`
- Modify: `Apps/Shared/Detail/MovieDetailView.swift`, `SeriesDetailView.swift`, `TitleDetailScreen.swift` (placering), `Apps/Shared/Player/PlayerScreenModel.swift` (skriv `TitleTechInfo` vid start), `Apps/Shared/AppModel+Subtitles.swift`, `Apps/Shared/Localizable.xcstrings`
- Test: `Apps/SharedTests/TitleInfoBoxModelTests.swift`

**Interfaces:**
- Consumes: `SubtitleStore.recordTechInfo/techInfo/list` (Task 3), `SubtitleSearchModel` (Task 6), `DetailPresentation`.
- Produces:
  ```swift
  struct TitleInfoModel: Equatable { var audio: [String]; var subtitles: [String]; var downloaded: [StoredSubtitle]; var video: String?; var engine: String?; var isEmpty: Bool }
  // AppModel+Subtitles
  func titleInfo(kind: ContentKind, providerID: String, playlistID: UUID) async -> TitleInfoModel?     // nil i barnläge
  func recordTechInfo(from session: PlaybackSession, request: PlaybackRequest, playlistID: UUID)         // anropas när motorn laddat; ingen skrivning på huvudtråden
  ```
  Rutan visar ljudspår, textspår (embedded + nedladdade), video ("2160p · Dolby Vision · …" ur `VideoInfo`) och spelare, med texten "Visas efter första uppspelningen" när inget sparats. Knappen "Sök undertexter" öppnar `SubtitleSearchSheet` utan pågående uppspelning (tvOS: Select-ark; iOS: blad); nedladdade undertexter kan tas bort (långt tryck/kontextmeny) och används nästa gång titeln spelas. Barnprofil ser ingen ruta. Serier: uppgifterna gäller senast spelade avsnitt, och sökning görs för det avsnittet.

- [ ] **Step 1: Write failing tests:** `infoModelFromRecordedTechInfo`, `emptyBeforeFirstPlayback`, `downloadedListedAndRemovable`, `kidsProfileGetsNilInfo`, `recordTechInfoWritesOffMainAndPerProfile`, `seriesUsesLastPlayedEpisode`.
- [ ] **Step 2: Run** (CI/Mac) → FAIL.
- [ ] **Step 3: Implement.** Informationsrutan läser en gång när detaljsidan visas (inte i `body`); formatering utanför `body`.
- [ ] **Step 4:** Verifiera i CI.
- [ ] **Step 5: Commit** `feat(detail): info-ruta med spår, video, spelare och undertexter`.

---

### Task 8: Prestanda, dokumentation och avslut

**Files:**
- Modify: `README.md`, `.github/workflows/nightly.yml` (bara om ett prestandatest läggs till), minnesfilen `project_iptv_app.md`
- Test: `Packages/IPTVKit/Tests/SubtitlesTests/SubtitlePerformanceTests.swift`

**Interfaces:**
- Consumes: allt ovan.
- Produces: README-testlista "Fas 5 på riktig Apple TV", signposts `subtitleSearch`/`subtitleParse` (`#if canImport(os)`, subsystem `se.sjodin.iptv`).

- [ ] **Step 1: Write perf test:** en genererad SRT med 5 000 cues tolkas på mindre än ett tak (skriv ut `PERF subtitle-parse <ms>`; generöst CI-tak) och `cue(at:offset:)` 100 000 uppslag stiger inte linjärt (binärsökning; skriv ut `PERF subtitle-lookup`).
- [ ] **Step 2: Run** lokalt (`swift test --filter SubtitlePerformanceTests`) och notera tiderna.
- [ ] **Step 3: README:** avsnittet "Nycklar" (OpenSubtitles) och testlista "Fas 5 på riktig Apple TV": registrera ett OpenSubtitles-konto och en API-nyckel (ingen nyckel i chatten, bara i `Secrets.xcconfig`); logga in i Inställningar och se dagskvoten; sök undertext på en film och ett avsnitt; svenska tecken (å ä ö) visas rätt; synkjustering ±0,1 s märks och sparas; byt motor mitt i en film och se att texten finns kvar; VLC visar undertexten; barnprofil har varken sökning, konto eller info-ruta; info-rutan på detaljsidan efter första uppspelning; slut dagskvot ger ett vänligt meddelande.
- [ ] **Step 4:** Hela sviten grön lokalt och i CI (`apple`, `kit-tests`, `performance`, `secrets`).
- [ ] **Step 5: Commit** `docs: fas 5 testlista och prestandatest`; öppna PR `fas5-opensubtitles`.

---

## Self-review (körd)

- **Spec-täckning §7.2:** konto i inställningar (Task 5), "Sök fler undertexter…" på TMDB/IMDb-id + säsong/avsnitt, i andra hand titel (Task 2/5/6; hash uttryckligen uppskjuten), sortering och dagskvot (Task 3/6), AVPlayer-överlagring och VLC `addPlaybackSlave` (Task 4/6), synk ± 0,1 s per titel (Task 3/4/6), lagring per titel och profil (Task 3), textutseende per profil (Task 5/6). §6.3 info-ruta (Task 7). §3 Keychain och nyckel (Task 3/5). §10 barnprofil (Task 5/6/7). Offline-följande av undertexter hör till fas 6 (lagringslayouten stöder det).
- **Typkonsistens:** `SubtitleKey` (Task 3) används av Task 5–7; `StoredSubtitle` och `OpenSubtitlesResult` oförändrade mellan Task 2, 3, 5, 6; `ext:<fileID>` skapas i Task 4 och används av Task 6.
- **Uppskjutet medvetet:** moviehash, ASS/PGS-rendering i AVPlayer, VLC-utseende bortom grundstorlek, undertextsökning från detaljsidan för flera avsnitt samtidigt, automatiska förslag på språk saknas i spåren.
