# Fas 4: Live TV och EPG – implementationsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Live TV med kanallista (favoriter, senast sedda, kategorier, liveförhandsvisning), zappning med info-overlay, kvalitetsmeny och en TV-tablå (EPG) byggd på XMLTV.

**Architecture:** Kanalgruppering (`ChannelGrouper`), `liveRequest` och en enkel Live-flik finns sedan fas 1/2 och byggs vidare på. Ny ren logik (XMLTV-tolk, kanal↔EPG-matchning) hamnar i `IPTVKit` så att den kan testas på Windows. Lagring (migrering v6, `EPGStore`) och import hamnar i `IPTVPlatform/Library`; UI och zappning i `Apps/Shared` (tvOS-specifikt bakom `#if os(tvOS)`). EPG importeras separat från katalogimporten och blockerar aldrig den.

**Tech Stack:** Swift 6, SwiftUI, GRDB, `XMLParser` (SAX), Compression (gzip, bara Apple), AVPlayer, `OSSignposter`.

**Spec:** `docs/superpowers/specs/2026-10-25-iptv-app-design.md` (§8 Live TV och TV-tablå, §9 prestanda, §14 fas 4). Fas 3b-planen (`2026-10-27-fas3b-netflix-ui.md`) beskriver `PreviewController`, `StreamConnectionBroker` och `Motion`, som den här planen återanvänder.

## Global Constraints

- Swift 6 strikt samtidighet; `@Observable`/`@MainActor` i UI; Swift Testing för tester.
- Ingen nätverksåtkomst eller databasskrivning på huvudtråden (§9). `LazyVStack`/`LazyHStack` med stabila id:n, inga dyra beräkningar i `body`.
- Kanalbyte < 2 s (beroende på leverantör); stäng föregående ström innan nästa öppnas om `max_connections` är 1 (§8.2).
- Live spelas alltid i AVPlayer om strömmen är HLS (§8.2). Barnprofil ser aldrig Live eller EPG (§10, `kidsRestricted` är sant utan profil).
- XMLTV tolkas som ström (SAX, gzip-stöd); fönstret −1 dag till +7 dagar sparas; koppling via `tvg-id`/`epg_channel_id`, i andra hand normaliserat namn (§8.3).
- Högsta kvalitet väljs automatiskt: 4K/UHD före FHD före HD före SD; HDR bara om skärmen stöder det (§8.1). Användaren kan dela upp en felaktig sammanslagning (§8.1).
- Inga hemligheter i kod, loggar, fel, fixtures eller commit. EPG-URL:er med inloggning får aldrig synas i felmeddelanden (`Redactor`). Fixtures anonymiseras med `iptv-anonymize`.
- Ingen Sport-funktion (ägaren valde bort det 2026-10-31).
- Svenska i commit-meddelanden; trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Nya UI-strängar i `Localizable.xcstrings` (engelska nycklar, svensk översättning).
- Apple-kod och Library/app-tester verifieras bara i CI; `IPTVKit` testas lokalt med `source scripts/swift-env.sh && cd Packages/IPTVKit && swift test`.
- Subagenter: bara `model: sonnet`; Opus bara efter verklig fastkörning, noterat i ledgern.

## Review Focus

1. **XMLTV-tid och fönster:** `+0100`/`-0500`-offset, saknad `stop`, program utanför −1d…+7d, sommartidsskifte → rätt UTC-tid, inget kraschar. Pinnas i Task 1.
2. **Avbruten eller trasig EPG-hämtning:** halv gzip, trasig XML eller nätfel får inte tömma befintlig tablå (atomär ersättning). Task 3 och 5.
3. **Miljontals rader:** 20 000 kanaler × 7 dagar. Bara program för kanaler som matchar en spellistekanal sparas. Task 1 (filter) och 3.
4. **Zappspam:** upprepade upp/ned-tryck ger bara sista kanalen och läcker ingen ström/lease. Task 9.
5. **Kanal utan EPG eller med delat `epg_channel_id`:** tom rad utan krasch; två grupper med samma id visar båda samma program. Task 4 och 11.
6. **Barnprofil:** inga live- eller EPG-vägar via `AppModel`. Task 7.
7. **Inloggning i EPG-URL:** fel och loggar innehåller aldrig URL:en. Task 2.

---

## File Structure

| Fil | Ansvar |
|---|---|
| `Packages/IPTVKit/Sources/Core/EPG.swift` (ny) | `EPGProgram`, `EPGChannel`, `NowNext` |
| `Packages/IPTVKit/Sources/Providers/XMLTVParser.swift` (ny) | SAX-tolk, fönster, kanalfilter |
| `Packages/IPTVKit/Sources/Providers/GzipFile.swift` (ny) | gzip-header och avpackning till fil |
| `Packages/IPTVKit/Sources/Providers/HTTPClient.swift` | `download(_:)` till fil |
| `Packages/IPTVKit/Sources/Providers/EPGSource.swift` (ny) | EPG-URL per spellista |
| `Packages/IPTVKit/Sources/Providers/Xtream/XtreamClient.swift` | `shortEPG(streamID:limit:)` |
| `Packages/IPTVKit/Sources/Providers/EPGMatcher.swift` (ny) | kanal↔XMLTV-koppling |
| `Packages/IPTVKit/Sources/Providers/ChannelGrouper.swift` | stöd för manuell uppdelning |
| `Packages/IPTVKit/Sources/Personal/PersonalStore.swift` | favoritkanaler, senast sedda |
| `Packages/IPTVPlatform/Sources/Library/AppDatabase.swift` | migrering v6 |
| `Packages/IPTVPlatform/Sources/Library/EPGStore.swift` (ny) | program, kanalkarta, uppdelningar |
| `Packages/IPTVPlatform/Sources/Library/EPGImporter.swift` (ny) | hämta, tolka, spara, uppdateringspolicy |
| `Apps/Shared/Live/` (ny) | `LiveModel`, `ChannelLogoView`, `LiveTabView`, `ChannelListView`, `ChannelPreview`, `EPGGridView`, `ZapController`, `ChannelInfoOverlay` |
| `Apps/Shared/AppModel+Live.swift` (ny) | live-API mot `AppModel` med barnspärr |
| `Apps/Shared/Player/` | zappning och kvalitetsmeny för live |

---

### Task 1: XMLTV-tolk

**Files:**
- Create: `Packages/IPTVKit/Sources/Core/EPG.swift`, `Packages/IPTVKit/Sources/Providers/XMLTVParser.swift`
- Create fixtures: `Packages/IPTVKit/Sources/ProvidersTestSupport/Fixtures/xmltv-sample.xml` (anonymiserad, ca 3 kanaler, program med olika offset, ett utan `stop`, ett utanför fönstret, ett med `&amp;` i titeln)
- Test: `Packages/IPTVKit/Tests/ProvidersTests/XMLTVParserTests.swift`

**Interfaces:**
- Consumes: —
- Produces:
  ```swift
  // Core/EPG.swift
  public struct EPGProgram: Sendable, Hashable, Codable { public var channelID: String; public var start: Date; public var end: Date; public var title: String; public var summary: String? }
  public struct EPGChannel: Sendable, Hashable { public var id: String; public var names: [String] }
  public struct NowNext: Sendable, Hashable { public var now: EPGProgram?; public var next: EPGProgram? }
  // Providers/XMLTVParser.swift
  public struct XMLTVParser: Sendable {
      public init(window: ClosedRange<Date>, wantedChannelIDs: Set<String>?)   // nil = alla
      public func parse(contentsOf file: URL, onChannel: (EPGChannel) -> Void, onProgram: (EPGProgram) -> Void) throws
  }
  public enum XMLTVError: Error, Sendable, Equatable { case unreadable, malformed }
  ```

- [ ] **Step 1: Write failing tests** i `XMLTVParserTests`:
  - `parsesChannelsWithAllDisplayNames`: fixturens kanaler ger rätt `id` och `names` i ordning.
  - `parsesTimeWithPositiveAndNegativeOffsets`: `20261031183000 +0100` → UTC 17:30; `-0500` → +5 h; utan offset tolkas som UTC.
  - `dropsProgramsOutsideWindow`: program som slutar före eller börjar efter fönstret kommer inte med; ett som överlappar fönstrets kant tas med.
  - `programWithoutStopEndsAtNextProgramStart`: saknad `stop` → slut = nästa programs start på samma kanal; sista programmet utan `stop` släpps.
  - `wantedChannelFilterSkipsOthers`: `wantedChannelIDs: ["a"]` ger inga program för andra kanaler (och ingen `onChannel` för dem).
  - `decodesEntitiesAndTrimsText`: `&amp;`, CDATA och omgivande blanktecken.
  - `malformedXMLThrowsMalformed` och `missingFileThrowsUnreadable`.
- [ ] **Step 2: Run:** `swift test --filter XMLTVParserTests` → FAIL (typer saknas).
- [ ] **Step 3: Implement** `EPG.swift` och `XMLTVParser` med `XMLParser(stream:)` över `InputStream(url:)` (`import FoundationXML` bakom `#if canImport(FoundationXML)`). Tidsformatet `yyyyMMddHHmmss[ ±HHmm]` tolkas för hand (ingen `DateFormatter`, för prestanda). Program utan `stop` hålls kvar per kanal tills nästa program eller strömmens slut.
- [ ] **Step 4: Run** `swift test --filter XMLTVParserTests` → PASS; kör hela `swift test`.
- [ ] **Step 5: Commit** `feat(providers): XMLTV-tolk med fönster och kanalfilter`.

---

### Task 2: Hämtning, gzip och EPG-källa

**Files:**
- Create: `Packages/IPTVKit/Sources/Providers/GzipFile.swift`, `Packages/IPTVKit/Sources/Providers/EPGSource.swift`
- Modify: `Packages/IPTVKit/Sources/Providers/HTTPClient.swift`
- Test: `Packages/IPTVKit/Tests/ProvidersTests/GzipFileTests.swift`, `EPGSourceTests.swift`

**Interfaces:**
- Consumes: `PlaylistSecret` (Core), `Redactor`.
- Produces:
  ```swift
  // HTTPClient (nytt krav med standardimplementation via get(_:) + temporärfil)
  func download(_ url: URL) async throws -> (file: URL, status: Int)   // URLSessionHTTPClient använder URLSession.download
  public enum GzipFile {
      public static func headerLength(_ prefix: Data) -> Int?            // nil = inte gzip (magiska bytes 1F 8B saknas) eller för kort
      public static func inflate(_ source: URL) throws -> URL            // returnerar temporär XML-fil; om filen inte är gzip returneras `source`
  }
  public enum EPGSource { public static func url(for secret: PlaylistSecret) -> URL? }  // Xtream: <server>/xmltv.php?username=&password=; M3U: epgURL
  ```

- [ ] **Step 1: Write failing tests:** `headerLength` för header med och utan `FNAME`/`FEXTRA`-flaggor (bytes konstruerade i testet), `nil` för vanlig XML och för tom data; `EPGSource` för båda hemlighetstyperna (M3U utan `epgURL` ger `nil`); `inflateOfPlainFileReturnsSameURL`; `corruptGzipThrows` (Apple-bara test för själva `inflate` bakom `#if canImport(Compression)`); ett test som visar att felbeskrivningen från `EPGSource`/hämtning aldrig innehåller URL:en (använd `Redactor`).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** `inflate` strippar gzip-headern och packar upp strömmande i delar med `compression_stream` (`COMPRESSION_ZLIB`) till en temporärfil; ingen hel fil i minnet. Utanför Apple kastar `inflate` en tydlig `ProviderError` för gzip-indata (EPG är då ej stött i CI på Linux; testerna är markerade därefter). Fel mappas till befintlig `ProviderError` utan URL.
- [ ] **Step 4: Run** `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(providers): EPG-hämtning till fil, gzip och EPG-källa`.

---

### Task 3: Lagring – migrering v6 och `EPGStore`

**Files:**
- Modify: `Packages/IPTVPlatform/Sources/Library/AppDatabase.swift` (migrering `v6`)
- Create: `Packages/IPTVPlatform/Sources/Library/EPGStore.swift`
- Test: `Packages/IPTVPlatform/Tests/LibraryTests/EPGStoreTests.swift` (CI)

**Interfaces:**
- Consumes: `EPGProgram`, `NowNext` (Task 1), `AppDatabase`/`LibraryStore`-mönstret (`db.writer`).
- Produces:
  ```swift
  public final class EPGStore: Sendable {
      public init(db: AppDatabase)
      /// Atomär: allt eller inget. Tidigare program för spellistan ersätts bara om batchen skrivs klart.
      public func replacePrograms(playlistID: UUID, programs: any Sequence<EPGProgram>, fetchedAt: Date) throws
      public func programs(playlistID: UUID, channelIDs: [String], in range: ClosedRange<Date>) throws -> [String: [EPGProgram]]
      public func nowNext(playlistID: UUID, channelIDs: [String], at date: Date) throws -> [String: NowNext]
      public func lastFetch(playlistID: UUID) throws -> Date?
      public func prune(before: Date) throws
      public func splitProviderIDs(playlistID: UUID) throws -> Set<String>      // manuell uppdelning
      public func setSplit(playlistID: UUID, providerID: String, split: Bool) throws
  }
  ```
  Tabeller: `epgProgram(playlistID, channelID, start REAL, end REAL, title, summary)` med index `(playlistID, channelID, start)`; `epgMeta(playlistID PRIMARY KEY, fetchedAt REAL)`; `channelSplit(playlistID, providerID, PRIMARY KEY(playlistID, providerID))`. Spellistans borttagning rensar alla tre (följ hur `liveStream` rensas vid borttagning).

- [ ] **Step 1: Write failing tests:** `replaceIsAtomicWhenSequenceThrowsMidway` (en sekvens som kastar efter N rader lämnar gamla programmen orörda och `lastFetch` oförändrad); `nowNextPicksCurrentAndFollowing`; `programsInRangeIncludesOverlappingAtEdges`; `programsForUnknownChannelAreEmpty`; `pruneRemovesOnlyOldPrograms`; `removingPlaylistRemovesEpgAndSplits`; `splitRoundTrips`.
- [ ] **Step 2: Run** (i CI) → FAIL. Lokalt: bekräfta att `swift build` av övriga paket är oförändrat.
- [ ] **Step 3: Implement** migrering och `EPGStore`; massinsättning via förberett statement i en transaktion (samma stil som `replaceCatalog`).
- [ ] **Step 4:** Verifiera i CI (`apple`-jobbet grönt).
- [ ] **Step 5: Commit** `feat(library): EPG-tabeller och EPGStore (migrering v6)`.

---

### Task 4: Kanal↔EPG-matchning och manuell uppdelning

**Files:**
- Create: `Packages/IPTVKit/Sources/Providers/EPGMatcher.swift`
- Modify: `Packages/IPTVKit/Sources/Providers/ChannelGrouper.swift`
- Test: `Packages/IPTVKit/Tests/ProvidersTests/EPGMatcherTests.swift`, utökning av befintligt `ChannelGrouper`-test

**Interfaces:**
- Consumes: `ChannelGroup`, `ChannelNameNormalizer`, `EPGChannel` (Task 1).
- Produces:
  ```swift
  public enum EPGMatcher {
      /// groupID → XMLTV-kanal-id. Först `epgChannelID` hos någon variant (bästa först), sedan normaliserat namn mot XMLTV-kanalernas `names`. Grupper utan träff saknas i resultatet.
      public static func match(groups: [ChannelGroup], xmltvChannels: [EPGChannel]) -> [String: String]
  }
  extension ChannelGrouper { public static func group(_ streams: [LiveStream], splitProviderIDs: Set<String>) -> [ChannelGroup] }
  ```
  En uppdelad variant blir en egen grupp med id `<ursprungligt id>\u{1F}split\u{1F}<providerID>`; befintliga `group(_:)` är oförändrad.

- [ ] **Step 1: Write failing tests:** `matchesByEpgChannelIDFirst`; `fallsBackToNormalizedName` ("SVT1 HD" ↔ XMLTV-namn "SVT 1"); `epgIDWinsOverNameWhenBothExist`; `twoGroupsMayShareOneXmltvID`; `unmatchedGroupIsAbsent`; `splitProviderIDBecomesOwnGroup` och `splitGroupKeepsRemainingVariantsTogether`; `noSplitsEqualsPlainGrouping`.
- [ ] **Step 2: Run** `swift test --filter EPGMatcherTests` → FAIL.
- [ ] **Step 3: Implement** `match` (namnindex byggs en gång: normaliserad nyckel → xmltv-id; vid dubletter vinner första) och `group(_:splitProviderIDs:)`.
- [ ] **Step 4: Run** `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(providers): koppla kanaler till EPG och stöd för manuell uppdelning`.

---

### Task 5: EPG-import, uppdateringspolicy och korta tablån

**Files:**
- Create: `Packages/IPTVPlatform/Sources/Library/EPGImporter.swift`
- Modify: `Packages/IPTVKit/Sources/Providers/Xtream/XtreamClient.swift` (+DTO för `get_short_epg`: titel och beskrivning är base64, tider är unix-sekunder eller text)
- Modify: `Apps/Shared/AppModel.swift` (starta uppdatering, se `AppModel+Live.swift` i Task 7)
- Test: `Packages/IPTVPlatform/Tests/LibraryTests/EPGImporterTests.swift`, `Packages/IPTVKit/Tests/ProvidersTests/XtreamShortEPGTests.swift`

**Interfaces:**
- Consumes: `EPGSource`, `GzipFile`, `XMLTVParser` (Task 1–2), `EPGMatcher` (Task 4), `EPGStore` (Task 3), `LibraryStore.channelGroups`, `CredentialStore`.
- Produces:
  ```swift
  public struct EPGImporter: Sendable {
      public static let refreshInterval: TimeInterval = 12 * 3600
      public init(store: LibraryStore, epg: EPGStore, credentials: CredentialStore, http: HTTPClient, clock: @Sendable @escaping () -> Date = Date.init)
      public func needsRefresh(playlistID: UUID) -> Bool
      /// Hämtar, tolkar med fönstret (−1 d … +7 d från `clock()`) och bara matchade kanaler, sparar atomärt. Returnerar antal program. Misslyckande lämnar gammal EPG orörd.
      public func refresh(playlistID: UUID) async throws -> Int
  }
  extension XtreamClient { public func shortEPG(streamID: String, limit: Int) async throws -> [EPGProgram] }
  ```
  Tvåpassmetod: pass 1 läser bara `<channel>`-element för att bygga matchningen; pass 2 tolkar program med `wantedChannelIDs` = matchade ids. Temporärfiler tas bort oavsett utfall.

- [ ] **Step 1: Write failing tests:** `refreshStoresOnlyMatchedChannels`; `refreshFailureKeepsOldPrograms` (HTTP-fel och halv fil); `needsRefreshAfterTwelveHours` med injicerad klocka; `noEpgSourceReturnsZeroWithoutTouchingStore`; `errorDescriptionNeverContainsURL`; `shortEPGDecodesBase64TitleAndSummary`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** `AppModel` kör `refresh` i bakgrunden (`Task.detached(priority: .utility)`) när Live-fliken öppnas om `needsRefresh`, aldrig för barnprofil, och aldrig parallellt två gånger per spellista.
- [ ] **Step 4:** Verifiera i CI.
- [ ] **Step 5: Commit** `feat(library): EPG-import med atomär ersättning och 12-timmarspolicy`.

---

### Task 6: Favoritkanaler och senast sedda

**Files:**
- Modify: `Packages/IPTVKit/Sources/Personal/PersonalStore.swift`
- Test: `Packages/IPTVKit/Tests/PersonalTests/` (följ befintlig testfil för `UserDefaultsPersonalStore`)

**Interfaces:**
- Consumes: —
- Produces (tillägg till `PersonalStore`; gamla JSON-blobbar utan fälten ska fortfarande avkodas):
  ```swift
  func favoriteChannels() -> [String]            // grupp-id, nyast först
  func toggleFavoriteChannel(_ groupID: String) -> Bool
  func recentChannels() -> [String]              // nyast först, högst 20
  func noteChannelWatched(_ groupID: String)     // flyttar först, dubbletter tas bort
  ```

- [ ] **Step 1: Write failing tests:** `favoritesToggleAndOrder`; `recentsCapAtTwentyAndDeduplicate`; `oldSnapshotWithoutChannelFieldsDecodes` (JSON från före ändringen); `persistsAcrossInstances`.
- [ ] **Step 2: Run** `swift test --filter Personal` → FAIL.
- [ ] **Step 3: Implement** (nya fält i `PersonalSnapshot` med standardvärden; samma lås och `persist()`).
- [ ] **Step 4: Run** `swift test` → PASS.
- [ ] **Step 5: Commit** `feat(personal): favoritkanaler och senast sedda kanaler`.

---

### Task 7: `LiveModel`, kanallogga och ny Live-flik (båda plattformarna)

**Files:**
- Create: `Apps/Shared/AppModel+Live.swift`, `Apps/Shared/Live/LiveModel.swift`, `Apps/Shared/Live/ChannelLogoView.swift`, `Apps/Shared/Live/LiveTabView.swift`
- Modify: `Apps/Shared/LibraryBrowserView.swift` (ersätt privata `LiveTab` med `LiveTabView`), `Apps/Shared/Localizable.xcstrings`
- Test: `Apps/SharedTests/LiveModelTests.swift`

**Interfaces:**
- Consumes: `LibraryStore.channelGroups`, `EPGStore`, `EPGMatcher`, `PersonalStore` (Task 6), `AppModel.liveRequest(group:playlistID:displaySupportsHDR:)`, `ArtworkImage`/`ArtworkPipeline(kind:)`.
- Produces:
  ```swift
  // AppModel+Live.swift – alla returnerar tom/nil när kidsRestricted
  func liveGroups(playlistID: UUID) async throws -> [ChannelGroup]       // med uppdelningar
  func epgMap(playlistID: UUID, groups: [ChannelGroup]) async -> [String: String]
  func nowNext(playlistID: UUID, xmltvIDs: [String], at: Date) async -> [String: NowNext]
  func toggleFavoriteChannel(_ groupID: String) -> Bool;  func noteChannelWatched(_ groupID: String)
  func splitChannel(playlistID: UUID, providerID: String, split: Bool) async
  // LiveModel (@Observable, @MainActor)
  struct Section: Identifiable { enum Kind { case favorites, recents, category(String) }; let id: String; let title: String; let groups: [ChannelGroup] }
  var sections: [Section]; var nowNext: [String: NowNext]; var loading: Bool; var failed: Bool
  func load() async;  func refreshNowNext(for visible: [ChannelGroup]) async     // anropas när synliga rader ändras, och var 60:e sekund
  // ChannelLogoView(group: ChannelGroup, size: CGSize) – logga via ArtworkImage; saknas den: textlogga (initialer på färg härledd stabilt från displayName)
  ```
  `nowNext` faller tillbaka på `XtreamClient.shortEPG` (cachad i minnet i 5 minuter) för Xtream-kanaler som saknar lagrad EPG.
  Ordning: Favoriter, Senast sedda, därefter kategorier i leverantörens ordning (tomma sektioner utelämnas). En grupp tillhör sin egen kategori; favoriter/senast sedda är kopior av referensen.

- [ ] **Step 1: Write failing tests** (`LiveModelTests`, CI): `sectionOrderIsFavoritesRecentsThenCategories`; `emptySectionsOmitted`; `kidsProfileGetsNoGroupsAndNoEpg` (alla `AppModel+Live`-anrop tomma, `liveRequest` nil); `nowNextOnlyForRequestedChannels`; `textLogoColorIsStablePerName`.
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement** modell, vyer och `AppModel+Live`. Databasläsning via `offMain`. `LiveTabView` är en `List` på iOS och ett fokusbart rutnät/rader på tvOS; kanalrad visar logga, namn, "Nu: …" och en tunn förloppsstapel. Långt tryck (tvOS) / kontextmeny (iOS): Favorit, Dela upp variant.
- [ ] **Step 4:** Verifiera i CI.
- [ ] **Step 5: Commit** `feat(app): ny Live-flik med favoriter, senast sedda, kategorier och nu-program`.

---

### Task 8: tvOS-kanallista med liveförhandsvisning

**Files:**
- Create: `Apps/Shared/Live/ChannelListView.swift`, `Apps/Shared/Live/ChannelPreview.swift`
- Modify: `Apps/Shared/Hero/PreviewController.swift` (live-stöd), `Packages/IPTVKit/Sources/PlaybackCore/PreviewPlan.swift` (live-regel)
- Test: `Packages/IPTVKit/Tests/PlaybackCoreTests/PreviewPlanLiveTests.swift`, `Apps/SharedTests/ChannelPreviewTests.swift`

**Interfaces:**
- Consumes: `PreviewController`, `FocusSettleGate`, `StreamConnectionBroker` (förhandsvisning tränger aldrig undan uppspelning), `LiveModel` (Task 7), `AppModel.liveRequest`.
- Produces:
  ```swift
  // PreviewPlan: live har ingen startposition (alltid live-kanten) och ingen längdgräns
  static func live() -> PreviewPlan
  // PreviewController
  func focus(channel group: ChannelGroup, playlistID: UUID)   // samma enda-ägare- och settle-regler som för titlar; ingen preview i barnläge
  ```
  `ChannelListView`: vänster kolumn med sektionerna från `LiveModel`; höger ruta med liten liveförhandsvisning av fokuserad kanal, programnamn, beskrivning och tid. Klick/Play öppnar helskärm (`PlayerPresentation`).

- [ ] **Step 1: Write failing tests:** `livePlanHasNoStartOffsetAndNoLimit`; `focusOnChannelStartsAfterSettleDelay`; `previewNeverEvictsPlayingStream` (brokern nekar när en uppspelning håller leasen, en nedladdning/preview får förloras); `kidsProfileNeverStartsChannelPreview`; `fastFocusMovesStartOnlyLastChannel`.
- [ ] **Step 2: Run** `swift test --filter PreviewPlanLiveTests` (lokalt) och CI-testet → FAIL.
- [ ] **Step 3: Implement.** Återanvänd hela livscykeln i `PreviewController` (attempt-hantering, `isolated deinit`-skyddsnät); lägg bara till kanalingång. Förhandsvisningen är tyst och använder samma yta (`PreviewSurface`).
- [ ] **Step 4:** Verifiera i CI.
- [ ] **Step 5: Commit** `feat(app): kanallista med liveförhandsvisning på tvOS`.

---

### Task 9: Zappning och info-overlay

**Files:**
- Create: `Apps/Shared/Live/ZapController.swift`, `Apps/Shared/Live/ChannelInfoOverlay.swift`
- Modify: `Apps/Shared/Player/PlayerScreen.swift`, `Apps/Shared/Player/PlayerScreenModel.swift`, `Apps/Shared/LibraryBrowserView.swift`/`LiveTabView` (skicka med zapplista)
- Test: `Apps/SharedTests/ZapControllerTests.swift`

**Interfaces:**
- Consumes: `AppModel.liveRequest`, `PlaybackSession.stopAndWait()`, `PlayerScreenModel.makeSession`, `NowNext` (Task 1), signposter (`se.sjodin.iptv`).
- Produces:
  ```swift
  @MainActor @Observable final class ZapController {
      init(groups: [ChannelGroup], start: String /* groupID */, request: @MainActor (ChannelGroup) -> PlaybackRequest?, switchTo: @MainActor (PlaybackRequest) async -> Void)
      var current: ChannelGroup { get }
      func zap(_ direction: Direction)          // enum Direction { case up, down }, runt vid kanterna
      func zapTo(_ groupID: String)
  }
  ```
  Regler: bara sista begäran vinner (tidigare, ännu ej startade byten avbryts); föregående session stängs med `stopAndWait` innan nästa öppnas; ett signpost-intervall `channelSwitch` från tryck till första bildruta. På tvOS byter upp/ned i helskärm kanal; overlayn visar logga, nu, nästa, tidslinje (förlopp) och döljs automatiskt efter samma tid som spelarens övriga overlay. Zappa i listan som `LiveTabView` skickade med (samma ordning som användaren valde den, inklusive Favoriter). Spelad kanal noteras med `noteChannelWatched`.

- [ ] **Step 1: Write failing tests:** `zapUpDownWrapsAround`; `rapidZapsOnlySwitchToLast` (5 snabba `zap` ger ett `switchTo` för sista kanalen); `previousSessionClosedBeforeNextOpens` (ordningslogg: close → open); `zapToUnknownIDIsIgnored`; `kidsProfileCannotZap` (`request` ger nil → inget byte, ingen krasch).
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement** `ZapController` med en enda pågående `Task` som ersätts vid varje `zap`; koppla in i `PlayerScreen` (fjärrkontroll upp/ned på tvOS, vertikal swipe på iOS) och i overlayn.
- [ ] **Step 4:** Verifiera i CI.
- [ ] **Step 5: Commit** `feat(player): zappa mellan kanaler med info-overlay`.

---

### Task 10: Kvalitetsmeny och förslag vid buffring

**Files:**
- Create: `Packages/IPTVKit/Sources/PlaybackCore/BufferingAdvisor.swift`
- Modify: `Apps/Shared/Player/PlayerMenus.swift`, `Apps/Shared/Player/PlayerScreenModel.swift`
- Test: `Packages/IPTVKit/Tests/PlaybackCoreTests/BufferingAdvisorTests.swift`, `Apps/SharedTests/PlayerScreenModelLiveQualityTests.swift`

**Interfaces:**
- Consumes: `ChannelGroup.variants` (bäst först) och dess kvalitet, `PlaybackSession`/`PlayerScreenModel`.
- Produces:
  ```swift
  public struct BufferingAdvisor: Sendable {
      public init(threshold: Int = 3, window: TimeInterval = 60)
      /// Anropas vid varje buffringsstart. `true` när `threshold` stannanden skett inom `window` sekunder; nollställs efter ett förslag och vid kanalbyte.
      public mutating func recordStall(at: Date) -> Bool
      public mutating func reset()
  }
  // PlayerScreenModel: var liveVariants: [LiveVariantOption] (namn + kvalitet + isCurrent); func selectVariant(_ providerID: String) async; var suggestLower: LiveVariantOption?
  ```
  Menyn listar kanalens varianter (bäst först). Förslaget är ett diskret banner "Byt till lägre kvalitet?" med en lägre variant; avvisas det visas det inte igen för den kanalen i samma uppspelning.

- [ ] **Step 1: Write failing tests:** `threeStallsWithinWindowSuggest`; `stallsOutsideWindowDoNotAccumulate`; `resetClearsHistory`; `noSuggestionWhenAlreadyLowest`; `selectingVariantSwitchesStreamViaStopAndWait`; `dismissedSuggestionNotShownAgain`.
- [ ] **Step 2: Run** `swift test --filter BufferingAdvisorTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** lokalt (kit) och verifiera app-testerna i CI.
- [ ] **Step 5: Commit** `feat(player): kvalitetsmeny för live och förslag vid buffring`.

---

### Task 11: TV-tablå (EPG-rutnät)

**Files:**
- Create: `Apps/Shared/Live/EPGGridView.swift`, `Apps/Shared/Live/EPGGridLayout.swift`, `Apps/Shared/Live/ProgramDetailView.swift`
- Modify: `Apps/Shared/Live/LiveTabView.swift` (växla Lista/Tablå), `Apps/Shared/Localizable.xcstrings`
- Test: `Apps/SharedTests/EPGGridLayoutTests.swift`

**Interfaces:**
- Consumes: `EPGStore.programs(playlistID:channelIDs:in:)`, `LiveModel`, `ZapController`/`liveRequest` (Titta nu).
- Produces:
  ```swift
  struct EPGGridLayout {   // ren, testbar geometri
      init(origin: Date, pointsPerMinute: CGFloat)
      func x(for date: Date) -> CGFloat
      func frame(for program: EPGProgram) -> (x: CGFloat, width: CGFloat)   // min bredd, beskärs mot origin
      func visibleRange(offset: CGFloat, viewport: CGFloat) -> ClosedRange<Date>
      var nowX: (Date) -> CGFloat
  }
  ```
  Kanaler vertikalt (`LazyVStack`, stabila id:n), tid horisontellt i en gemensam horisontell scroll; en "nu"-linje; tidsaxel i 30-minuterssteg. Programrutor hämtas för synligt tidsfönster ±1 timme och visade kanaler (batchat, utanför huvudtråden), inte för hela veckan. Valt program öppnar `ProgramDetailView` med namn, beskrivning och tid, och knappen "Titta nu" bara när programmet sänds. Kanal utan program visar en tom rad ("Ingen tablå"). Två grupper med samma XMLTV-id visar samma program.

- [ ] **Step 1: Write failing tests** (`EPGGridLayoutTests`): `xIsLinearInMinutes`; `programBeforeOriginIsClipped`; `veryShortProgramGetsMinimumWidth`; `visibleRangeMatchesOffsetAndViewport`; `nowXMatchesXForNow`.
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement** layout, grid och detaljvy. Inga formateringar eller databasanrop i `body`; formaterade tider cachas per program-id.
- [ ] **Step 4:** Verifiera i CI.
- [ ] **Step 5: Commit** `feat(app): TV-tablå med rutnät, nu-linje och Titta nu`.

---

### Task 12: Prestanda, dokumentation och avslut

**Files:**
- Modify: `Apps/SharedTests/` (prestandatest enligt befintligt mönster för Nightly perf), `README.md`, `docs/superpowers/specs/2026-10-25-iptv-app-design.md` (bara om något beslut ändrats), minnesfilen `project_iptv_app.md`
- Test: `Packages/IPTVPlatform/Tests/LibraryTests/EPGPerformanceTests.swift`

**Interfaces:**
- Consumes: allt ovan.
- Produces: signposts `epgImport`, `channelSwitch`, `epgQuery` i subsystem `se.sjodin.iptv`; README-testlista "Fas 4 på riktig Apple TV".

- [ ] **Step 1: Write perf test:** genererad XMLTV med 2 000 kanaler × 7 dagar tolkas och sparas utan att minnet växer med filstorleken (mät topp-RSS mot tak), och `nowNext` för 100 kanaler mot en full databas svarar under 50 ms.
- [ ] **Step 2: Run** i CI (Nightly) och notera tid.
- [ ] **Step 3: README:** lägg till testlista på riktig Apple TV: kanalbyte under 2 s, upp/ned-zappning, kanallistans förhandsvisning, kvalitetsmeny, tablå (nu-linje, Titta nu), barnprofil utan Live, EPG med gzip från den egna leverantören (ingen URL i texten).
- [ ] **Step 4:** Hela sviten grön i CI (`apple`, `kit-tests`, `secrets`).
- [ ] **Step 5: Commit** `docs: fas 4 testlista och prestandatest`; öppna PR `fas4-live-tv-epg`.

---

## Self-review (körd)

- **Spec-täckning §8.1:** gruppering finns (fas 1), uppdelning Task 4/7, kvalitetsmeny + förslag Task 10, loggor + textlogga Task 7. **§8.2:** zappning + overlay Task 9, kanallista + förhandsvisning + Favoriter/Senast sedda Task 6–8, AVPlayer för HLS är befintlig motorlogik, stäng-före-öppna Task 9. **§8.3:** rutnät Task 11, XMLTV SAX + gzip Task 1–2, fönster och matchning Task 1/4/5. **§9:** kanalbyte, off-main, signposts Task 9/12. **§10:** barnprofil Task 7/8/9.
- **Typkonsistens:** `EPGProgram`/`NowNext`/`EPGChannel` (Task 1) används oförändrade i 3, 4, 5, 7, 11; `ChannelGroup.id` är nyckeln för favoriter (6), zapp (9) och EPG-karta (7).
- **Uppskjutet medvetet:** `get_short_epg` används bara som reserv när full EPG saknas för en kanal (Task 5 bygger klienten, Task 7 visar "Nu" från den om lagrad EPG saknas); iPhone/iPad-anpassad zappning (fas 6); EPG-sökning.
