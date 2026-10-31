# Fas 6b: Nedladdningar (offline på iPhone och iPad) – implementationsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** På iPhone och iPad kan användaren ladda ner film, avsnitt, hel säsong eller "nästa 3 avsnitt" i bakgrunden (även med appen stängd och låsskärm), pausa/återuppta, se förlopp och utrymme, spela offline med rätt motor, och få undertexter, artwork och metadata sparade med så att offlineläget ser ut som online.

**Architecture:** Ren logik (köns tillståndsmaskin, planering av vad som ska hämtas, filnamn, utrymmesberäkning, inställningar) i en ny IPTVKit-modul `Downloads` som testas på Linux. `DownloadStore` (GRDB, migrering v8) bor i `IPTVPlatform/Library` bredvid `SubtitleStore` och sparar *ögonblicksbilder* av titeln (ingen FK mot `movie`/`episode`, eftersom en import kan radera dem). Bakgrunds-`URLSession`, appdelegatens återanslutning, `NWPathMonitor` och kopplingen till `StreamConnectionBroker` bor i appmålet (`Apps/Shared/Downloads`, `#if !os(tvOS)`) bakom ett `DownloadTransport`-protokoll så att `DownloadManager` kan testas med fakes. Offlineuppspelning återanvänder `PlaybackSession` med en lokal fil-URL.

**Tech Stack:** Swift 6, SwiftUI, GRDB, `URLSession` (bakgrundskonfiguration), Network.framework (`NWPathMonitor`), Nuke (befintlig), `StreamConnectionBroker`.

**Spec:** `docs/superpowers/specs/2026-10-25-iptv-app-design.md` (§3 hemligheter, §7.2 sista punkten, §9 prestanda, §10 profiler, §11 nedladdningar). Fas 6a-planen (`2026-10-31-fas6a-iphone-ipad.md`) beskriver iOS-navigationen (`LibraryBrowserView`, `LibrarySection`), `LayoutMetrics` och spelarens struktur; fas 5-planen beskriver `SubtitleStore`/`SubtitleKey`.

## Global Constraints

- Swift 6 strikt samtidighet; `@Observable`/`@MainActor` i UI; Swift Testing. **tvOS får inte ändras i beteende**; all nedladdningskod är iOS/iPadOS (`#if !os(tvOS)`), `Downloads`-modulen är plattformsneutral ren logik.
- **Spec §11** [Beslutat]: film, avsnitt, hel säsong eller "nästa 3 avsnitt"; `URLSession` i bakgrundsläge som klarar att appen stängs och låsskärm; pausa och återuppta; förlopp och utrymme; inställning "bara via wifi"; undertexter, artwork och metadata sparas med; offlineuppspelning använder samma motorlogik (MKV → VLC, MP4 → AVPlayer); **respektera `max_connections`**: nedladdningar köas och pausas när en uppspelning behöver anslutningen; valfritt: radera automatiskt när titeln är sedd, och hämta nästa avsnitt automatiskt via wifi (inställningar, av som standard).
- **Per profil** [§10, §11]: nedladdningar hör till (profil, spellista). Barnprofil: nedladdningsfliken, nedladdningsknappar och offlinelistan saknas; titlar utan godkänd åldersgräns får aldrig laddas ner eller spelas offline av barnprofil; offlinespelning kontrollerar profilen på nytt (kan inte använda `AppModel.playbackRequest`).
- **Hemligheter** [§3]: stream-URL:er innehåller uppgifter och byggs först vid start från `StreamLocator` + `PlaylistSecret`. De sparas aldrig i databasen, filnamn, loggar, fel eller signposts. Databasen lagrar `StreamLocator` och relativa filsökvägar. Fel är fasta värden utan servertext eller URL. Filnamn bygger på id:n, aldrig titlar.
- **Fil- och nätverksåtkomst aldrig på huvudtråden** (§9). Filer lagras under Application Support (`LibraryLocation.downloadsDirectory()`), med `isExcludedFromBackup = true`; relativa sökvägar i databasen (containerns sökväg ändras mellan installationer).
- **Ögonblicksbilder:** `replaceCatalog` kan radera en film eller serie efter en import; nedladdningsraden sparar titel, år, container, säsong/avsnitt, längd, poster/backdrop/still som egna filer och får aldrig bero på `movie`/`episode`-rader.
- En HTTP-status utanför 2xx, för liten fil eller fel `Content-Type` (HTML-felsida) får aldrig sparas som en färdig video: raden blir `failed`, filen raderas.
- Lågt diskutrymme: starta inte en nedladdning som inte ryms (beräknat med marginal), pausa med tydligt meddelande när utrymmet tar slut mitt i.
- Svenska i commit-meddelanden; trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Nya UI-strängar i `Localizable.xcstrings` (engelska nycklar, svensk översättning, giltig JSON, nycklar i alfabetisk ordning där grannarna är det).
- Apple-kod verifieras bara i CI (eller på Macen); ren logik placeras i `IPTVKit` och testas lokalt (`source scripts/swift-env.sh && cd Packages/IPTVKit && swift test`). **Per-fil-import-revision** före varje commit av Apple-kod; `Library.LibraryItem` kvalificeras. Testfiler: hjälpare som rör `@MainActor`-tillstånd är `@MainActor`, globala closures `@Sendable` (CI-fel i fas 5 och 6a). Verifiera isolering av konstanter/closures som läses från `@Sendable`-hanterare (`nonisolated`).
- Subagenter: bara `model: sonnet`; Opus bara efter verklig fastkörning, noterat i ledgern.

## Review Focus

1. **Barnprofil:** ingen flik, inga knappar, inga nedladdade titlar i listan och ingen offlinespelning av olämpliga titlar, även om en annan profil laddat ner dem; profilbyte mitt i en nedladdning kastar inte om raderna. Task 2, 3, 6, 7.
2. **`max_connections` och uppspelning:** en uppspelning ska alltid få sin plats; en nedladdning som pausas för det återupptas automatiskt efteråt; en bakgrunds-session som fortsätter medan appen är avstängd får inte hålla kvar en lease eller strida mot en ny uppspelning vid återupptagen förgrund. Task 4.
3. **Fel som ser ut som framgång:** 401/403/404/5xx, HTML-felsida, tom eller avklippt fil, utgånget abonnemang. Raden blir `failed`, ingen trasig fil spelas. Task 4.
4. **Disk full / lågt utrymme / appen dödas mitt i / nätbyte (wifi → mobil med "bara wifi"):** inga korrupta halva filer markerade som klara, återupptagning med resume data, tydlig status. Task 1, 4.
5. **Katalogändring efter nedladdning:** spellistan uppdateras och titeln försvinner eller byter id; nedladdningen finns kvar och spelas. Spellistan raderas: rader (cascade) och filer städas. Task 2.
6. **Hemligheter:** inga URL:er med uppgifter i databas, logg, fel, signposts eller filnamn. Task 2, 4.
7. **Offlineläge:** ingen felspam; bläddring begränsas till det som finns offline; serieavsnitt utan nedladdning spelas inte "nästa avsnitt" offline. Task 3, 9.
8. **Samtidig åtkomst:** pausa/ta bort/spela samma fil; borttagning av en fil som spelas. Task 2, 6.

---

## File Structure

| Fil | Ansvar |
|---|---|
| `Packages/IPTVKit/Package.swift` | ny target/produkt `Downloads` + `DownloadsTests` |
| `Packages/IPTVKit/Sources/Downloads/DownloadModels.swift` (ny) | `DownloadKey`, `DownloadState`, `DownloadSnapshot`, `DownloadFailure` |
| `Packages/IPTVKit/Sources/Downloads/DownloadQueue.swift` (ny) | ren tillståndsmaskin för kön |
| `Packages/IPTVKit/Sources/Downloads/DownloadPlanner.swift` (ny) | vad en begäran (film/avsnitt/säsong/nästa 3) expanderas till |
| `Packages/IPTVKit/Sources/Downloads/DownloadPaths.swift`, `DownloadSpace.swift` (nya) | filnamn/relativa sökvägar, utrymmesberäkning |
| `Packages/IPTVKit/Sources/PlaybackCore/Settings.swift` | `DownloadSettings` i `PlaybackSettings` |
| `Packages/IPTVPlatform/Sources/Library/AppDatabase.swift`, `DownloadStore.swift` (ny) | migrering v8, ögonblicksbilder, filer |
| `Packages/IPTVPlayback/Sources/Playback/PlaybackSession.swift` | lokal källa (`PlaybackRequest.localURL`), valfri hemlighet |
| `Apps/Shared/Downloads/DownloadTransport.swift`, `BackgroundDownloadTransport.swift`, `DownloadManager.swift`, `NetworkPolicy.swift` (nya) | bakgrunds-URLSession, kö, broker, nät |
| `Apps/Shared/AppModel+Downloads.swift` (ny), `AppModel.swift` | API med barnspärr, offlinebegäran, `live()`-koppling |
| `Apps/Shared/Player/PlayerOrientation.swift` (appdelegaten) | `handleEventsForBackgroundURLSession` |
| `Apps/Shared/Downloads/DownloadsView.swift`, `DownloadButton.swift` (nya), `LibraryBrowserView.swift`, `Detail/*`, `Settings/*` | UI |
| `Apps/Shared/LibraryLocation.swift` | `downloadsDirectory()` |
| `README.md`, `.github/workflows/*` | testlista, perf |

---

### Task 1: Modulen `Downloads` – modeller, kö, planering och utrymme

**Files:**
- Modify: `Packages/IPTVKit/Package.swift` (target `Downloads` med beroenden `Core`, `PlaybackCore`; test-target `DownloadsTests`; produkt `Downloads`), `Packages/IPTVKit/Sources/PlaybackCore/Settings.swift` (`DownloadSettings`)
- Create: `Packages/IPTVKit/Sources/Downloads/DownloadModels.swift`, `DownloadQueue.swift`, `DownloadPlanner.swift`, `DownloadPaths.swift`, `DownloadSpace.swift`
- Test: `Packages/IPTVKit/Tests/DownloadsTests/*`, `Packages/IPTVKit/Tests/PlaybackCoreTests/DownloadSettingsTests.swift`

**Interfaces:**
- Consumes: `ContentKind`, `StreamLocator`, `Episode` (Core).
- Produces:
  ```swift
  public struct DownloadKey: Sendable, Hashable { public var profileID: UUID; public var playlistID: UUID; public var kind: ContentKind /* .movie/.series(avsnitt) */; public var providerID: String }
  public enum DownloadState: Sendable, Equatable { case queued, downloading(progress: Double), paused(PauseReason), completed, failed(DownloadFailure) }
  public enum PauseReason: Sendable, Equatable { case user, connectionNeeded, waitingForWifi, lowDiskSpace }
  public enum DownloadFailure: String, Sendable, Equatable { case badStatus, badContent, noSpace, storage, expired, network, unknown }   // fasta värden, ingen servertext
  public struct DownloadSnapshot: Sendable, Equatable { /* titel, år, säsong/avsnitt, container, durationSeconds, seriesProviderID, seriesTitle, locator, expectedBytes?, addedAt */ }
  public struct DownloadQueue: Sendable {            // ren reducer, ingen I/O
      public init(maxConcurrent: Int)
      public mutating func enqueue(_ key: DownloadKey)
      public mutating func apply(_ event: DownloadEvent) -> [DownloadCommand]   // events: progress, finished, failed(DownloadFailure), connectionRevoked, connectionGranted, networkChanged(allowsCellular:), userPaused/Resumed/Cancelled, spaceChanged(freeBytes:)
      public var states: [DownloadKey: DownloadState] { get }
  }
  public enum DownloadCommand: Sendable, Equatable { case start(DownloadKey), pause(DownloadKey), cancel(DownloadKey), requestConnection(DownloadKey), releaseConnection(DownloadKey) }
  public enum DownloadPlanner {
      public enum Request: Sendable { case movie(String), episode(String, seriesID: String), season(Int, seriesID: String), nextEpisodes(count: Int, after: String?, seriesID: String) }
      public static func plan(_ request: Request, episodes: [Episode], alreadyDownloaded: Set<String>, watched: Set<String>) -> [String]   // providerID i spelordning, utan dubbletter/redan hämtade
  }
  public enum DownloadPaths { public static func relativeDirectory(for key: DownloadKey) -> String; public static func fileName(container: String?) -> String }   // id-baserat, tillåtna tecken, aldrig titel
  public enum DownloadSpace { public static func canStart(expectedBytes: Int64?, freeBytes: Int64, reserveBytes: Int64) -> Bool }
  // PlaybackCore
  public struct DownloadSettings: Codable, Equatable, Sendable { public var wifiOnly = true; public var autoDeleteWatched = false; public var autoNextEpisode = false }   // PlaybackSettings.downloads, decodeIfPresent
  ```
  Kölogik: `maxConcurrent` är 1 (kan höjas); en uppspelning (`connectionRevoked`) pausar pågående som `.paused(.connectionNeeded)` och återupptar automatiskt vid `connectionGranted`; `networkChanged(allowsCellular: false)` pausar som `.paused(.waitingForWifi)` när `wifiOnly`; en `user`-paus återupptas aldrig automatiskt; `failed` släpper anslutningen och startar nästa i kön.

- [ ] **Step 1: Write failing tests:** `enqueueStartsFirstAndQueuesRest`, `finishedStartsNext`, `revokeThenGrantResumesAutomatically`, `userPauseIsNotAutoResumed`, `wifiOnlyPausesOnCellularAndResumesOnWifi`, `failedReleasesConnectionAndStartsNext`, `cancelRemovesAndReleases`, `lowSpacePausesAsLowDiskSpace`, `duplicateEnqueueIgnored`; planner: `seasonExpandsInOrderSkippingDownloaded`, `nextThreeStartsAfterLastWatchedOrGivenEpisode`, `nextEpisodesCrossesSeasonBoundary`, `nextEpisodesStopsAtEndOfSeries`, `movieAndEpisodePlanSingle`; paths: `pathsNeverContainTitleOrUnsafeCharacters` (providerID med `/`, `..`, unicode, långa värden → säkert, begränsad längd, unikt per nyckel), `unknownContainerFallsBackToMp4OrBin`; space: `rejectsWhenNotEnoughWithReserve`, `unknownSizeAllowedWithReserveCheck`; settings: `downloadSettingsDefaultsAndOldBlobDecodes`.
- [ ] **Step 2: Run** `swift test --filter DownloadsTests` → FAIL.
- [ ] **Step 3: Implement** modulen (alla typer `Sendable`, ingen Apple-API). Tillståndsmaskinen är en ren funktion av (tillstånd, händelse) → (tillstånd, kommandon).
- [ ] **Step 4: Run** `swift test` → PASS (hela sviten).
- [ ] **Step 5: Commit** `feat(downloads): kö, planering, filnamn och utrymme som ren logik`.

---

### Task 2: `DownloadStore` och migrering v8

**Files:**
- Modify: `Packages/IPTVPlatform/Sources/Library/AppDatabase.swift` (migrering `v8`), `Packages/IPTVPlatform/Package.swift` (beroende `Downloads`), `Packages/IPTVPlatform/Tests/LibraryTests/MigrationTests.swift` (v1…v8)
- Create: `Packages/IPTVPlatform/Sources/Library/DownloadStore.swift`
- Test: `Packages/IPTVPlatform/Tests/LibraryTests/DownloadStoreTests.swift`

**Interfaces:**
- Consumes: Task 1-typer, `AppDatabase`-mönstret, `SubtitleStore` (nyckelform).
- Produces:
  ```swift
  public struct StoredDownload: Sendable, Equatable, Identifiable { public var key: DownloadKey; public var snapshot: DownloadSnapshot; public var state: DownloadState; public var bytesWritten: Int64; public var fileURL: URL?  /* absolut, byggd ur relativ sökväg */; public var artworkURLs: DownloadArtwork; public var id: String { get } }
  public struct DownloadArtwork: Sendable, Equatable { public var poster: URL?; public var backdrop: URL?; public var still: URL? }
  public final class DownloadStore: Sendable {
      public init(db: AppDatabase, directory: URL)
      public func insert(_ snapshot: DownloadSnapshot, key: DownloadKey) throws -> StoredDownload      // state .queued; nyckelkonflikt → befintlig rad
      public func list(profileID: UUID, playlistID: UUID?) throws -> [StoredDownload]
      public func download(for key: DownloadKey) throws -> StoredDownload?
      public func updateState(_ state: DownloadState, bytesWritten: Int64, for key: DownloadKey) throws
      public func resumeData(for key: DownloadKey) throws -> Data?;  public func setResumeData(_ data: Data?, for key: DownloadKey) throws   // fil, inte databasen
      public func completeMoving(from temp: URL, for key: DownloadKey, expectedMinBytes: Int64) throws -> StoredDownload   // flyttar atomärt, verifierar storlek, markerar completed, exkluderar från backup
      public func saveArtwork(poster: Data?, backdrop: Data?, still: Data?, for key: DownloadKey) throws
      public func remove(_ key: DownloadKey) throws                   // rad + fil + artwork + resume data
      public func purgeOrphans() throws                               // filer utan rad; rader vars fil saknas (completed → failed(.storage))
      public func totalBytes(profileID: UUID) throws -> Int64
  }
  ```
  Tabell `download(profileID, playlistID REFERENCES playlist(id) ON DELETE CASCADE, kind, providerID, snapshotJSON, state, progress, bytesWritten, relativePath, addedAt, PRIMARY KEY(profileID, playlistID, kind, providerID))`. **Ingen FK mot `movie`/`episode`.** `locator` ligger i `snapshotJSON` (aldrig en löst URL).

- [ ] **Step 1: Write failing tests:** `insertAndListPerProfile` (annan profil ser inget), `snapshotSurvivesCatalogReplace` (radera film/serie ur katalogen → raden och snapshot kvar), `removingPlaylistCascadesRows`, `purgeOrphansRemovesFilesWithoutRow`, `purgeMarksMissingFileAsFailedStorage`, `completeMovingRejectsTooSmallFile` (→ ingen completed-rad, filen raderas), `completeMovingIsAtomicAndRelative` (sökvägen relativ), `removeDeletesFilesAndArtwork`, `pathsCannotEscapeDirectory` (providerID `../x`), `snapshotJSONNeverContainsCredentialsOrAbsoluteURLWithSecrets` (locator-serialisering har bara servertom `StreamLocator`), `totalBytesPerProfile`, `stateRoundTripsAllCases`, `concurrentCompleteAndRemoveDoesNotCorrupt`.
- [ ] **Step 2: Run** (CI/Mac) → FAIL.
- [ ] **Step 3: Implement** enligt `SubtitleStore`-mönstret (`ioLock`, atomär skrivning, inga `try?` som sväljer skrivfel). `MigrationTests` förväntar `v1…v8`.
- [ ] **Step 4:** CI grönt.
- [ ] **Step 5: Commit** `feat(library): nedladdningslagring med ögonblicksbilder (migrering v8)`.

---

### Task 3: Offlineuppspelning

**Files:**
- Modify: `Packages/IPTVPlayback/Sources/Playback/PlaybackSession.swift` (`PlaybackRequest.localURL`, valfri hemlighet), `Apps/Shared/AppModel+Downloads.swift` (ny, offlinebegäran), `Apps/Shared/AppModel.swift` (`nextEpisodeProvider` offline), `Apps/Shared/Player/PlayerScreen.swift` (hoppa över broker/hemlighet offline)
- Test: `Packages/IPTVPlayback/Tests/PlaybackTests/OfflinePlaybackTests.swift`, `Apps/SharedTests/OfflineRequestTests.swift`

**Interfaces:**
- Consumes: `StoredDownload` (Task 2), `EngineSelector`, `ProgressKey`.
- Produces:
  ```swift
  // PlaybackRequest: ny valfri egenskap, standard nil (alla befintliga anrop oförändrade)
  public var localURL: URL?
  // PlaybackSession.init(request:secret: PlaylistSecret? = nil, ...) — start()/reload()/retry() använder localURL före locator.resolve; saknas både localURL och secret → fail(.unknown)
  // AppModel+Downloads
  func offlineRequest(for download: StoredDownload) async throws -> PlaybackRequest   // kids-kontroll på nytt (kastar .notAllowed), container = filändelse → EngineSelector, localURL satt, startAt ur userState (samma ProgressKey som online), isLive false
  func offlineNextEpisodeProvider(for request: PlaybackRequest) -> (@MainActor () async -> PlaybackRequest?)?   // bara nästa avsnitt som är nedladdat och färdigt
  ```
  Spelaren startas utan broker (`broker: nil`) och utan nätverksanrop för hemlighet. Tidigare sparade undertexter laddas som vanligt via `storedSubtitles(for:)` (kräver inget nätverk). Sparad position delas mellan strömning och offline (samma `ProgressKey`).

- [ ] **Step 1: Write failing tests:** `localURLShortCircuitsResolveAndNeedsNoSecret`, `missingBothLocalURLAndSecretFails`, `mkvPicksVLCAndMp4PicksAVPlayerFromExtension`, `existingOnlineRequestsUnchanged`, `reloadAndRetryUseLocalURL`, `offlineRequestRechecksKids` (barnprofil + olämplig titel → `.notAllowed` även om raden finns), `offlineRequestUsesSameProgressKeyAsOnline`, `offlineNextEpisodeSkipsNotDownloaded`, `offlineNextEpisodeNilAtEnd`, `playerSkipsBrokerWhenOffline`.
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement.** Hemligheten blir valfri i `PlaybackSession` med standard nil; `PlayerScreen.setUp` hoppar över `playbackSecret(for:)` och `broker` när `request.localURL != nil`.
- [ ] **Step 4:** CI grönt (alla befintliga uppspelningstester oförändrade).
- [ ] **Step 5: Commit** `feat(playback): spela nedladdade filer offline med rätt motor`.

---

### Task 4: Bakgrundsöverföring och `DownloadManager`

**Files:**
- Create: `Apps/Shared/Downloads/DownloadTransport.swift`, `BackgroundDownloadTransport.swift`, `DownloadManager.swift`, `NetworkPolicy.swift` (alla `#if !os(tvOS)`)
- Modify: `Apps/Shared/Player/PlayerOrientation.swift` (`OrientationAppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)` → `DownloadSessionEvents.shared`), `Apps/Shared/AppModel.swift` (`live()` bygger store/transport/manager; injicerbart för tester), `Apps/Shared/LibraryLocation.swift` (`downloadsDirectory()`)
- Test: `Apps/SharedTests/DownloadManagerTests.swift` (fakes), `Apps/SharedTests/NetworkPolicyTests.swift`

**Interfaces:**
- Consumes: `DownloadQueue` (Task 1), `DownloadStore` (Task 2), `StreamConnectionBroker` (`acquire(.download, ...)`, `release`), `AppModel.playbackSecret(for:)`, `StreamLocator.resolve`.
- Produces:
  ```swift
  protocol DownloadTransport: Sendable {
      func start(_ request: DownloadTransportRequest) async throws -> DownloadTaskHandle   // URL byggs här ur locator+secret, hålls aldrig utanför transporten
      func pause(_ handle: DownloadTaskHandle) async -> Data?        // resume data
      func cancel(_ handle: DownloadTaskHandle) async
      var events: AsyncStream<DownloadTransportEvent> { get }       // progress(bytes,total), finished(tempFile, status, contentType), failed(Error→DownloadFailure), backgroundEventsFinished
      func reattach() async -> [DownloadTaskHandle]                  // vid appstart: tasks som systemet fortsatt
  }
  @MainActor @Observable final class DownloadManager {
      init(store: DownloadStore, transport: any DownloadTransport, broker: StreamConnectionBroker, network: NetworkPolicy, freeSpace: @Sendable () -> Int64, secret: @Sendable (UUID) async throws -> PlaylistSecret)
      var items: [StoredDownload] { get }                    // observerbart, för UI
      func enqueue(_ snapshot: DownloadSnapshot, key: DownloadKey) async throws
      func pause(_ key: DownloadKey) / resume(_ key: DownloadKey) / cancel(_ key: DownloadKey) async
      func playbackWillNeedConnection(playlistID: UUID) async    // anropas när broker revokar
      func applicationDidBecomeActive() async                    // återsynka: stoppa nedladdningar om en uppspelning har platsen
  }
  struct NetworkPolicy { /* NWPathMonitor-wrapper: isOnWifi, isOnline; AsyncStream; allowsCellularAccess sätts på bakgrundskonfigurationen */ }
  ```
  Regler: bakgrundskonfiguration `URLSessionConfiguration.background(withIdentifier: "se.sjodin.iptv.downloads")` med `sessionSendsLaunchEvents = true`, `isDiscretionary = false`, `allowsCellularAccess` ur `DownloadSettings.wifiOnly`; en lease (`acquire(.download)`) per aktiv nedladdning med `onRevoke` som pausar (resume data sparas via `setResumeData`); `nil` från `acquire` → `queued`/`paused(.connectionNeeded)` och försök igen vid frisläppning; filen flyttas **synkront i delegatens `didFinishDownloadingTo`** via `completeMoving` (annars raderar systemet den); svar utanför 2xx, `text/html`-svar eller för liten fil → `failed(.badStatus/.badContent)`; 401/403 → `failed(.expired)`; lite utrymme → `paused(.lowDiskSpace)`; vid `applicationDidBecomeActive` stoppas nedladdningar om en uppspelning redan äger platsen (en bakgrunds-session kan ha fortsatt utan lease). Hemlighetsupplösning sker per start; URL:en och uppgifterna loggas aldrig och hamnar aldrig i fel (`DownloadFailure` är fasta värden).

- [ ] **Step 1: Write failing tests** (fake-transport, fake-broker via riktig `StreamConnectionBroker` med `setLimit(1)`): `enqueueAcquiresDownloadLeaseAndStarts`, `noFreeSlotQueuesThenStartsOnRelease`, `playbackRevokePausesAndSavesResumeData`, `afterPlaybackReleaseResumesAutomatically`, `userPauseNotAutoResumed`, `badStatusMarksFailedAndDeletesTemp`, `htmlContentTypeMarksBadContent`, `tooSmallFileMarksBadContent`, `unauthorizedMarksExpired`, `lowSpacePausesBeforeStart`, `cellularPausesWhenWifiOnlyAndResumesOnWifi`, `finishedMovesFileAndReleasesLease`, `reattachAdoptsRunningTasksOnLaunch`, `becomingActiveWithPlaybackLeaseCancelsDownloads`, `failureNeverContainsURLOrCredentials` (`String(describing:)` av fel/tillstånd/log), `profileSwitchMidDownloadKeepsOriginalProfileRows`.
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement.** `BackgroundDownloadTransport` är en tunn `URLSessionDownloadDelegate`-adapter (ingen logik utöver att översätta till `DownloadTransportEvent`); logiken ligger i `DownloadManager`/`DownloadQueue`. Appdelegaten lagrar systemets completion handler i `DownloadSessionEvents.shared` (`@MainActor`) och anropar den när `backgroundEventsFinished` kommit.
- [ ] **Step 4:** CI grönt.
- [ ] **Step 5: Commit** `feat(downloads): bakgrundsnedladdning med anslutningsvakt och nätpolicy`.

---

### Task 5: App-API, metadata och artwork som följer med

**Files:**
- Modify: `Apps/Shared/AppModel+Downloads.swift`, `Apps/Shared/DesignSystem/ArtworkImage.swift` (föredra lokal fil), `Apps/Shared/AppModel+Subtitles.swift` (kontroll att offline-nyckel = `SubtitleKey`)
- Test: `Apps/SharedTests/DownloadAPITests.swift`

**Interfaces:**
- Consumes: `DownloadManager` (Task 4), `DownloadPlanner` (Task 1), `AppModel.episodes(for:playlistID:)`, `LibraryStore` (film/avsnitt/serie), `ArtworkPipeline`/Nuke, `MetadataStore`.
- Produces:
  ```swift
  // alla kastar .notAllowed / returnerar tomt för barnprofil och utan aktiv profil
  var downloadsAvailable: Bool { get }                       // inte barnläge, iOS, store finns
  func downloadMovie(providerID: String, playlistID: UUID) async throws
  func downloadEpisode(providerID: String, seriesProviderID: String, playlistID: UUID) async throws
  func downloadSeason(_ season: Int, seriesProviderID: String, playlistID: UUID) async throws
  func downloadNextEpisodes(count: Int, seriesProviderID: String, after episodeProviderID: String?, playlistID: UUID) async throws
  func downloadState(for key: DownloadKey) -> DownloadState?        // för knappar
  func removeDownload(_ key: DownloadKey) async
  ```
  Varje nedladdning sparar en ögonblicksbild (titel, år, serietitel, säsong/avsnitt, container, längd, locator) och hämtar poster, backdrop och still (TMDB-bild om metadata finns, annars leverantörens) som lokala filer via `saveArtwork` (fel i artwork stoppar aldrig nedladdningen). Säsonger går via `episodes(for:)` (hämtar `get_series_info` vid behov). `ArtworkImage` får ett valfritt lokalt filsteg: finns en nedladdad fil för titeln används den före nätverk/Nuke-cache. Undertexter: `SubtitleStore` är redan per (profil, spellista, typ, providerID); en nedladdning får aldrig radera dem, och `removeDownload` raderar bara videofil/artwork (undertexterna hör till titeln, inte nedladdningen).

- [ ] **Step 1: Write failing tests:** `kidsProfileCannotDownloadAnything` (alla API:n kastar/tomt, ingen transportanrop), `noProfileIsKids`, `downloadMovieStoresSnapshotAndEnqueues`, `seasonPlansOnlyMissingEpisodesInOrder`, `nextThreeUsesLastWatchedWhenNoAnchor`, `snapshotKeepsDataAfterCatalogDelete`, `artworkFailureDoesNotFailDownload`, `removeKeepsSubtitles`, `downloadStateReflectsManager`, `episodesFetchedLazilyForSeason`.
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement.** Planering och barnspärr först, sedan `enqueue` per titel; offmain för all I/O.
- [ ] **Step 4:** CI grönt.
- [ ] **Step 5: Commit** `feat(downloads): app-API, ögonblicksbild och lokal artwork`.

---

### Task 6: Fliken Nedladdningar

**Files:**
- Create: `Apps/Shared/Downloads/DownloadsView.swift`, `DownloadRow.swift`, `DownloadsViewModel.swift`
- Modify: `Apps/Shared/LibraryBrowserView.swift` (`LibrarySection.downloads`, `Tab("Downloads", ...)` efter Sök; döljs för barnprofil precis som Live), `Apps/Shared/Localizable.xcstrings`
- Test: `Apps/SharedTests/DownloadsViewModelTests.swift`

**Interfaces:**
- Consumes: `DownloadManager.items`, `AppModel+Downloads`, `offlineRequest(for:)`, `LayoutMetrics`, `PlayerPresentation`/`playerCover`, `DownloadStore.totalBytes`.
- Produces:
  ```swift
  @MainActor @Observable final class DownloadsViewModel {
      init(manager: DownloadManager, kids: @MainActor () -> Bool, freeBytes: @Sendable () -> Int64)
      struct Section: Identifiable { var title: String; var rows: [Row] }       // Filmer, Serier (gruppt per serie/säsong), Pågående överst
      struct Row: Identifiable, Equatable { id; title; subtitle; state; progress; sizeText; canPlay; actions: [Action] }
      var sections: [Section] { get }; var totalSizeText: String { get }; var freeSpaceText: String { get }; var isEmpty: Bool { get }
      func perform(_ action: Action, on row: Row) async     // pausa, återuppta, avbryt, radera, spela
  }
  ```
  Listan visar förlopp, tillstånd ("Väntar på wifi", "Pausad – uppspelning pågår", "Slut på utrymme"), storlek och ledigt utrymme; svep/kontextmeny för radera; spela öppnar `PlayerScreen` med `offlineRequest`. Barnprofil: fliken saknas och modellen ger tom lista. Rader hämtas inte i `body`.

- [ ] **Step 1: Write failing tests:** `sectionsGroupSeriesAndPutActiveFirst`, `statesMapToReadableRows`, `kidsGetsEmptyAndNoTab`, `playActionBuildsOfflineRequest`, `deleteActionRemovesRowAndFile`, `totalAndFreeSpaceText`, `emptyState`, `deletingPlayingItemIsBlocked` (aktivt spelad fil kan inte raderas under uppspelning).
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement** modell + vy (`List` med lata rader, stabila id:n, `LayoutMetrics`-anpassad på iPad).
- [ ] **Step 4:** CI grönt.
- [ ] **Step 5: Commit** `feat(ios): fliken Nedladdningar med förlopp, utrymme och offlinespelning`.

---

### Task 7: Nedladdningsknappar och inställningar

**Files:**
- Create: `Apps/Shared/Downloads/DownloadButton.swift`, `Apps/Shared/Settings/DownloadSettingsView.swift`
- Modify: `Apps/Shared/Detail/MovieDetailView.swift`, `SeriesDetailView.swift`, `EpisodeShelf.swift`, `Apps/Shared/Settings/SettingsView.swift`, `Apps/Shared/Localizable.xcstrings`
- Test: `Apps/SharedTests/DownloadButtonModelTests.swift`

**Interfaces:**
- Consumes: `AppModel+Downloads`, `downloadState(for:)`, `DownloadSettings` (via `AppModel.settings`).
- Produces:
  ```swift
  enum DownloadButtonState: Equatable { case hidden, available, queued, downloading(Double), paused, completed, failed }
  struct DownloadButtonModel { static func state(for: DownloadState?, available: Bool) -> DownloadButtonState }   // ren
  ```
  Film: knapp i knapprad (ikon + förlopp). Avsnitt: liten knapp per rad. Serie: meny "Ladda ner säsong" och "Nästa 3 avsnitt". Knappen visas bara när `downloadsAvailable` (iOS, inte barn). Inställningar (iOS, ej barn): "Bara via wifi" (på som standard), "Radera sedda automatiskt" (av), "Hämta nästa avsnitt automatiskt via wifi" (av). Inget av detta visas på tvOS.

- [ ] **Step 1: Write failing tests:** `hiddenForKidsAndTvOS`, `stateMappingCoversAllDownloadStates`, `completedShowsPlayableState`, `settingsTogglesPersistPerProfile`, `settingsDefaults`.
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement** knappmodellen (ren) och vyerna; inställningsraderna binder mot `$model.settings.downloads.*`.
- [ ] **Step 4:** CI grönt.
- [ ] **Step 5: Commit** `feat(ios): nedladdningsknappar på detaljsidor och inställningar`.

---

### Task 8: Automatik och städning

**Files:**
- Modify: `Apps/Shared/Downloads/DownloadManager.swift`, `Apps/Shared/AppModel.swift` (anrop vid sedd-markering, appstart, profilborttagning), `Apps/Shared/Player/PlayerScreenModel.swift` (efter sedd-gräns)
- Test: `Apps/SharedTests/DownloadAutomationTests.swift`, `Packages/IPTVKit/Tests/DownloadsTests/AutomationRulesTests.swift`

**Interfaces:**
- Consumes: `DownloadSettings`, `userState` (90 %-regeln i spec §7.3), `DownloadPlanner.nextEpisodes`, `DownloadStore.purgeOrphans`.
- Produces:
  ```swift
  // Downloads (rent)
  public enum DownloadAutomation { public static func shouldDeleteAfterWatch(settings: DownloadSettings, watchedFraction: Double) -> Bool; public static func nextEpisodeToFetch(settings: DownloadSettings, onWifi: Bool, hasQueuedOrActive: Bool, nextUndownloaded: String?) -> String? }
  ```
  Efter att ett avsnitt/en film passerat sedd-gränsen och `autoDeleteWatched`: radera nedladdningen (aldrig medan den spelas). Med `autoNextEpisode`: när ett avsnitt blivit sett eller en serie har ett nedladdat avsnitt med färre än 1 osett kvar, köa nästa via wifi (aldrig mobil). Vid appstart: `purgeOrphans`, avstämning mot transportens återanslutna tasks, och städning av nedladdningar för raderade spellistor/profiler (profil borttagen → dess rader och filer bort).

- [ ] **Step 1: Write failing tests:** rent: `deleteAfterWatchOnlyAtThresholdAndWhenEnabled`, `nextEpisodeOnlyOnWifiAndWhenEnabled`, `noNextWhenQueueBusy`, `noNextAtSeriesEnd`; app: `watchedAutoDeleteRemovesFileNotSubtitles`, `playingItemIsNeverAutoDeleted`, `profileRemovalPurgesItsDownloads`, `startupPurgeRunsOffMain`, `autoNextRespectsKids` (inget för barnprofil).
- [ ] **Step 2: Run** `swift test --filter AutomationRulesTests` (lokalt) → FAIL; resten i CI.
- [ ] **Step 3: Implement** reglerna rent, anslut dem i `AppModel`/`DownloadManager`.
- [ ] **Step 4:** Lokala tester gröna; CI grönt.
- [ ] **Step 5: Commit** `feat(downloads): automatisk radering av sedda och nästa avsnitt via wifi`.

---

### Task 9: Offlineläge, prestandatest, dokumentation och avslut

**Files:**
- Create: `Apps/Shared/Downloads/OfflineState.swift` (`#if !os(tvOS)`), `Packages/IPTVKit/Tests/DownloadsTests/DownloadPerformanceTests.swift`
- Modify: `Apps/Shared/HomeView.swift`/`LibraryBrowserView.swift` (offlinebanner och dämpade fel), `README.md`, `.github/workflows/nightly.yml` (bara om det passar mönstret)
- Test: `Apps/SharedTests/OfflineStateTests.swift`

**Interfaces:**
- Consumes: `NetworkPolicy` (Task 4).
- Produces: `@MainActor @Observable final class OfflineState { var isOffline: Bool }` (hysteres så att korta nätbortfall inte blinkar). När offline: en tydlig banner "Du är offline – visar nedladdat" överst, nätverksfel från Hem/detalj/EPG visas inte som felmeddelanden, Fliken Nedladdningar kan öppnas och spela, andra flikar visar sin cache utan felspam; så fort nätet är tillbaka försvinner bannern.

- [ ] **Step 1: Write failing tests:** `offlineStateDebouncesShortLoss`, `offlineSuppressesNetworkErrorToasts`, `onlineClearsBanner`, `kidsStillGatedWhenOffline`; perf: `queueReducer10kEventsFast` (10 000 progress-händelser på 200 köade poster under ett generöst tak; skriv ut `PERF download-queue <ms>`), `plannerLargeSeriesFast` (säsong med 500 avsnitt).
- [ ] **Step 2: Run** lokalt `swift test --filter DownloadPerformanceTests` och notera tiderna.
- [ ] **Step 3: README** "Testlista fas 6b (riktig iPhone/iPad)": ladda ner en film och ett avsnitt, hel säsong och nästa 3; förlopp och ledigt utrymme; stäng appen/lås skärmen och se att nedladdningen fortsätter; flygplansläge → spela offline (MP4 med AVPlayer, MKV med VLC), undertexter och synk finns kvar, position delas med strömning; start en uppspelning medan nedladdning pågår (nedladdningen pausar och återupptas) med `max_connections` = 1; "bara via wifi" pausar på mobildata; slut på utrymme; döda appen mitt i och starta om; spellistan uppdateras så att titeln försvinner (nedladdningen finns kvar); radera spellista/profil (filer städas); barnprofil har ingen flik, inga knappar och kan inte spela annans nedladdning; auto-radera sedda och auto nästa avsnitt; offlinebannern.
- [ ] **Step 4:** Hela sviten grön lokalt och i CI (`apple`, `kit-tests`, `performance`, `secrets`; iPad-bygget).
- [ ] **Step 5: Commit** `docs: fas 6b testlista och offlineläge`; öppna draft-PR `fas6b-nedladdningar`.

---

## Utanför denna plan

- iCloud-synk och TestFlight (fas 7), inspelning/catch-up (icke-mål), nedladdning på tvOS (spec: endast iOS/iPadOS), M3U-fil från Filer (egen liten uppgift senare).
- Nedladdning av live-strömmar, bakgrundsuppdatering av katalogen (`BGAppRefreshTask`).
- Nedladdningshastighet/begränsning (`isDiscretionary` är av; bildhastighetsdetaljer lämnas).

## Self-review (körd)

- **Spec §11:** film/avsnitt/säsong/nästa 3 (Task 1, 5, 7), bakgrunds-URLSession (4), pausa/återuppta (1, 4), förlopp och utrymme (6), bara-wifi-inställning (1, 4, 7), undertexter/artwork/metadata (5), offlinemotor (3), `max_connections` (1, 4), valfria autoregler (8). §10: barnprofil (2, 3, 5, 6, 7, 8). §9: ingen I/O på huvudtråden (4, 5, 6).
- **Typer:** `DownloadKey`/`DownloadState` (Task 1) används oförändrade i 2, 4, 5, 6, 7; `StoredDownload` (2) i 3, 6; `DownloadSettings` (1) i 7, 8; `PlaybackRequest.localURL` (3) i 6. `DownloadPlanner.Request` (1) matchar `downloadSeason/NextEpisodes` (5).
- **Review Focus:** varje rad har tester i sin task (barn: 2/3/5/6/7/8; broker: 4; felstatusar: 4; disk/död app: 1, 4, 9 testlistan; katalogändring: 2; hemligheter: 2, 4; offline: 3, 9; samtidighet: 2, 6).
- **Proportion:** nio uppgifter, signaturer och testnamn utan kroppar.
