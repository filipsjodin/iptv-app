# Fas 7: iCloud-synk och TestFlight – implementationsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Profiler, historik, Min lista, betyg, uppspelningsinställningar, textförskjutningar och spellistornas metadata synkas mellan användarens enheter via CloudKit (privat databas), spellistornas inloggningar (och profil-PIN) via iCloud Keychain – och ett TestFlight-jobb finns förberett men avstängt. **Appen ska fortfarande byggas, signeras (gratis konto) och fungera fullt ut lokalt utan utvecklarkonto**; synk slås på först när kontot finns.

**Architecture:** All synklogik som går att göra ren (poster, tidsstämplar, gravstenar, sammanslagningsregler, mappning till/från dagens lagringsformat, konvergens) bor i en ny IPTVKit-modul `Sync` och testas på Windows/Linux, inklusive en tvåenhetssimulering mot en `InMemorySyncTransport`. En `SyncCoordinator` i appen kopplar butikerna (UserDefaults/GRDB) mot ett `SyncTransport`-protokoll; `CloudKitTransport` (CKSyncEngine) är den enda koden som rör CloudKit och skapas bara när synk är tillgängligt (xcconfig-flagga + entitlements som läggs på enbart i synk-/TestFlight-bygget). iCloud Keychain är en egen opt-in (`kSecAttrSynchronizable`).

**Tech Stack:** Swift 6, CloudKit (`CKSyncEngine`, privat databas, egen zon), Security/Keychain, GRDB (migrering v10), XcodeGen + xcconfig, GitHub Actions (`xcodebuild archive/-exportArchive` med App Store Connect API-nyckel).

**Spec:** `docs/superpowers/specs/2026-10-25-iptv-app-design.md` (§3 distribution/iCloud/hemligheter, §10 profiler, §12 synk, §13 CI). Fas 6b-planen beskriver `DownloadStore` m.m. (nedladdningar synkas **inte**).

## Global Constraints

- Swift 6 strikt samtidighet; Swift Testing; `@Observable`/`@MainActor` i UI. **tvOS är med** (Apps/Shared byggs för båda); synk-UI och -logik gäller båda plattformarna, men nedladdningar finns bara på iOS och synkas inte.
- **Spec §3** [Beslutat]: iCloud/CloudKit fungerar bara med betalt konto → allt ska fungera fullt ut lokalt utan det; **gratis-signering får aldrig brytas**: inga `com.apple.developer.icloud-*`-entitlements i standardbygget, och `CKContainer`/`CKSyncEngine` får aldrig skapas när synk inte är aktiverat i bygget (annars kraschar appen utan entitlement).
- **Spec §12** [Beslutat]: CloudKit privat databas synkar profiler, historik, Min lista, betyg och inställningar; spellistornas inloggningar via iCloud Keychain (`kSecAttrSynchronizable`). Stabila id:n och tidsstämplar; konflikter: **senaste skrivning vinner per fält, för position "längst kommen"**.
- **Hemligheter** [§3]: aldrig i git, loggar, CloudKit-poster eller fel. CloudKit-poster innehåller **aldrig** server-URL, användarnamn, lösenord, M3U-URL eller PIN-hash; spellistposten har bara id, namn, typ, skapad. Inloggningar och PIN-hashar synkas endast via iCloud Keychain och endast när användaren slagit på det.
- **Kids/PIN:** `isKids` och `hasPin` synkas med profilen; PIN-hashen följer iCloud Keychain-valet. PIN-lockout (`profiles.pinLockout.v1`), nedladdningar, undertextfiler, OpenSubtitles-inloggning och engångscache synkas **inte**.
- **Aldrig huvudtråden** för synk-I/O (§9). Skrivningar till CloudKit buffras och strypas (förlopp skrivs var 10:e sekund lokalt; synk högst var 60:e sekund samt vid paus/stäng/bakgrund).
- **Tid:** tidsstämplar injiceras (`now: () -> Date`/`SyncClock`), aldrig `Date()` i ren logik; framtida tidsstämplar från fjärrenheter klampas till `now + 1 dygn` (felställd klocka ska inte vinna för evigt).
- Svenska i commit-meddelanden; trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Nya UI-strängar i `Localizable.xcstrings` (engelska nycklar, svensk översättning, giltig JSON).
- Apple-kod verifieras bara i CI (eller på Macen); ren logik i `IPTVKit`, lokalt: `source scripts/swift-env.sh && cd Packages/IPTVKit && swift test`. **Per-fil-import-revision** före varje commit av Apple-kod. CloudKit kan inte testas i CI (ingen container): `CloudKitTransport` hålls tunn och dess rena delar (post↔`CKRecord`-fältmappning) testas separat.
- Subagenter: bara `model: sonnet`; Opus bara efter verklig fastkörning, noterat i ledgern.

## Review Focus

1. **Uppståndelse efter radering:** en enhet som varit offline och sedan pushar en gammal post får inte återuppliva något som raderats på en annan enhet (gravstenar med tidsstämpel; gravsten vs senare återskapande avgörs av tidsstämpel). Gäller profil (och alla dess data), Min lista-objekt, betyg, spellista.
2. **Dubbla standardprofiler:** ny enhet får spellistan före profilerna → `ensureDefaultProfile` får inte skapa "Profile 1" innan första hämtningen är klar (annars dubbletter för alltid).
3. **Gratis-signering och krasch:** standardbygget (utan Sync-xcconfig) får inte referera entitlements och får aldrig röra CloudKit; test: `SyncAvailability` är falsk utan flagga, koordinatorn är då en no-op och appen beter sig exakt som före fas 7.
4. **Hemligheter:** inga inloggningsuppgifter/URL:er/PIN-hashar i CloudKit-poster eller loggar; borttagning av en synkroniserad Keychain-post raderar den på **alla** enheter → avstängning av Keychain-synk får aldrig radera iCloud-kopian utan uttryckligt val.
5. **Skrivförstärkning och ordning:** positionsuppdateringar är frekventa (stryp), poster kommer i godtycklig ordning (sammanslagning är kommutativ och idempotent; konvergenstest), kapacitetsgränser (500 framsteg, 1000 Min lista, 2000 betyg) ger samma resultat på alla enheter.

---

## Fil- och ansvarsöversikt

**Nya (IPTVKit, plattformsneutralt, testat lokalt):** `Packages/IPTVKit/Sources/Sync/{SyncRecord,SyncClock,SyncMerge,SyncMapper,SyncState}.swift`, `Tests/SyncTests/*`.
**Nya (IPTVPlatform):** `Sources/Sync/CloudKitTransport.swift` (+ `CKRecordCoding.swift` ren), `Sources/Secrets/` ändringar för synkroniserbar Keychain.
**Nya (appen):** `Apps/Shared/Sync/{SyncCoordinator,SyncAvailability,SyncSettingsView}.swift`, `Apps/Config/{Sync.xcconfig,Sync.entitlements}`, `.github/workflows/testflight.yml`.
**Ändrade:** `Profile`, `PersonalStore`, `UserState`, `Settings`, `PlaylistMetadataStore`, `SubtitleStore` + migrering v10, `AppModel`/`ProfileSession`, `SettingsView`, `Apps/project.yml`, `Apps/Config/Base.xcconfig`, `README.md`.

---

### Task 1: Synkkärna – poster, klocka, sammanslagning

**Files:**
- Create: `Packages/IPTVKit/Sources/Sync/{SyncRecord,SyncClock,SyncMerge}.swift`; ny target `Sync` i `Packages/IPTVKit/Package.swift` (+ produkt, + `SyncTests`)
- Test: `Packages/IPTVKit/Tests/SyncTests/SyncMergeTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SyncRecordID: Hashable, Codable, Sendable { public var kind: SyncKind; public var key: String }   // key = stabilt id, t.ex. "<profileUUID>/<itemKey>"
  public enum SyncKind: String, Codable, Sendable { case playlist, profile, progress, watchlistItem, rating, playbackSettings, channelFavorite, subtitleOffset }
  public struct SyncRecord: Equatable, Codable, Sendable { public var id: SyncRecordID; public var payload: Data?; public var updatedAt: Date; public var deleted: Bool; public var origin: String }   // payload nil + deleted == gravsten; origin = enhets-id (tie-break)
  public protocol SyncClock: Sendable { func now() -> Date }; public struct SystemSyncClock: SyncClock
  public enum SyncMerge { public static func merge(local: SyncRecord?, remote: SyncRecord, now: Date) -> SyncRecord }
  ```
- Regler (spec §12): senaste `updatedAt` vinner; lika tidsstämpel → lägre `origin` (deterministiskt); gravsten vinner bara om dess `updatedAt` ≥ postens; `remote.updatedAt` klampas till `now + 1 dygn`; **`progress`: position = max av båda (längst kommen), `watched` = OR, övriga fält från senaste**; merge är kommutativ, associativ och idempotent.

- [ ] **Step 1: Write failing tests:** `latestWriteWinsPerRecord`, `tieBreaksOnOriginDeterministically`, `tombstoneBeatsOlderUpdate`, `laterRecreationBeatsTombstone`, `futureTimestampIsClamped`, `progressKeepsFurthestPositionAndWatchedFlag`, `mergeIsCommutativeAssociativeIdempotent` (alla permutationer av 4 poster ger samma resultat), `payloadOfLoserIsNotMixedIn`.
- [ ] **Step 2: Run** `swift test --filter SyncMergeTests` → FAIL.
- [ ] **Step 3: Implement** typerna och `SyncMerge`; progress-payloaden avkodas som `WatchProgress`-liknande JSON (`SyncProgressPayload { position, duration?, watched }`, definierad här så att modulen inte beror på PlaybackCore).
- [ ] **Step 4:** Lokala tester gröna. **Step 5: Commit** `feat(sync): poster, klocka och sammanslagningsregler`.

---

### Task 2: Tidsstämplar och gravstenar i dagens datamodell

**Files:**
- Modify: `Packages/IPTVKit/Sources/Personal/{Profile,PersonalStore}.swift`, `PlaybackCore/{Settings,UserState}.swift`, `Core/Models.swift` (Playlist-metadata om det behövs), `Apps/Shared/PlaylistMetadataStore.swift`
- Test: `Packages/IPTVKit/Tests/PersonalTests/TimestampTests.swift`, `PlaybackCoreTests/…`

**Interfaces:**
- Produces (alla avkodningar tolerant med `decodeIfPresent`; saknad tidsstämpel = `Date.distantPast`, så att äldre lokal data aldrig skriver över nyare fjärrdata men fortfarande pushas):
  ```swift
  Profile.updatedAt: Date                                   // sätts vid varje ändring (namn, avatar, isKids, hasPin)
  PersonalSnapshot: watchlist: [WatchlistEntry{item, addedAt, removedAt?}], ratings: [RatingEntry{item, rating?, updatedAt}], favoriteChannels: [...{id, updatedAt, removedAt?}]
  PlaybackSettings.updatedAt: Date                          // en tidsstämpel per profil-inställningsblob (record-LWW; avvikelse mot "per fält" noterad i ledgern)
  ```
  Borttagning = `removedAt` (gravsten) i stället för att posten raderas; gravstenar rensas efter 90 dagar (`prune(now:)`); `PersonalStore`-API:t utåt (toggle, setRating, lista i ordning) är oförändrat: Min lista sorteras på `addedAt`. Kapacitet 1000/2000/500 tillämpas på levande poster med samma urvalsregel överallt (äldsta `updatedAt` först).
- [ ] **Step 1: Write failing tests:** `legacyBlobsDecodeWithDistantPastTimestamps`, `toggleOffLeavesTombstoneAndHidesItem`, `watchlistOrderFollowsAddedAt`, `capacityEvictsOldestLiveEntriesOnly`, `tombstonesPrunedAfterNinetyDays`, `settingsChangeBumpsUpdatedAt`, `profileEditBumpsUpdatedAt`, `existingPublicAPIBehaviourUnchanged` (befintliga tester ska passera oförändrade).
- [ ] **Step 2–4:** Run → FAIL → implementera → gröna (hela sviten). **Step 5: Commit** `feat(sync): tidsstämplar och gravstenar i profil-, personlig- och inställningsdata`.

---

### Task 3: Mappning mellan lagringsformat och synkposter + tvåenhetssimulering

**Files:**
- Create: `Packages/IPTVKit/Sources/Sync/{SyncMapper,SyncState,InMemorySyncTransport}.swift`
- Test: `Packages/IPTVKit/Tests/SyncTests/{SyncMapperTests,TwoDeviceConvergenceTests}.swift`

**Interfaces:**
- Consumes: Task 1–2.
- Produces:
  ```swift
  public protocol SyncTransport: Sendable {
      func fetchChanges() async throws -> [SyncRecord]               // sedan förra lyckade hämtningen (transporten äger token)
      func push(_ records: [SyncRecord]) async throws
      var remoteChanges: AsyncStream<Void> { get }                   // "något nytt finns"
  }
  public final class InMemorySyncTransport: SyncTransport        // delad "moln"-instans; flera enheter, valfri fördröjning/omordning/fel för test
  public enum SyncMapper {                                        // ren: tillstånd <-> poster
      static func records(profile:, personal:, progress:, settings:, now:) -> [SyncRecord]
      static func apply(_ records: [SyncRecord], to state: inout SyncableState, now: Date) -> SyncChangeSet
  }
  public struct SyncableState { /* profiler, personal per profil, framsteg per profil, inställningar per profil, spellistmetadata, textförskjutningar */ }
  ```
  Nycklar: `profile/<uuid>`, `progress/<profileUUID>/<playlistUUID>/<kind>/<providerID>`, `watchlist/<profileUUID>/<kind>/<providerID>`, `rating/…`, `settings/<profileUUID>`, `playlist/<uuid>` (utan hemligheter), `subtitleOffset/<profileUUID>/<playlistUUID>/<kind>/<providerID>`. `apply` rapporterar vilka profiler/poster som ändrats (för UI-uppdatering) och skapar **inte** nya lokala ändringar (ingen eko-loop). Borttagen profil = gravsten på `profile/<uuid>` **och** på alla dess barnposter (mottagande enhet raderar all profildata lokalt).
- [ ] **Step 1: Write failing tests:** `recordsContainNoSecretsOrURLs` (serialisera alla poster, assert saknar server/lösenord/`http`), `applyDoesNotEchoLocalChanges`, `profileTombstoneRemovesAllChildData`, `twoDevicesConvergeAfterArbitraryInterleaving` (slumpad ordning, seedat), `offlineDeviceCannotResurrectDeletedProfile`, `furthestPositionWinsAcrossDevices`, `capacityLimitsConvergeIdentically`, `newDeviceGetsFullStateFromCloud`, `transportFailureKeepsDirtyRecordsForRetry`.
- [ ] **Step 2–4:** Run → FAIL → implementera → gröna. **Step 5: Commit** `feat(sync): mappning, transportprotokoll och tvåenhetssimulering`.

---

### Task 4: Textförskjutningar och spellistmetadata i synk (migrering v10)

**Files:**
- Modify: `Packages/IPTVPlatform/Sources/Library/{AppDatabase,SubtitleStore}.swift` (migrering **v10**: `subtitleOffset.updatedAt REAL NOT NULL DEFAULT 0`), `Apps/Shared/PlaylistMetadataStore.swift` (gravstenar för borttagna spellistor, `updatedAt`)
- Test: `Packages/IPTVPlatform/Tests/LibraryTests/{MigrationTests,SubtitleStoreTests}.swift`

**Interfaces:**
- Produces: `SubtitleStore.offsets(profileID:) -> [(SubtitleKey, offsetMs, updatedAt)]`, `applyRemoteOffset(_:key:updatedAt:)` (äldre än lokal ändras inte; ändrar inte `addedAt`/filer); `PlaylistMetadataStore` kan ta emot fjärrspellista (id, namn, typ, skapad) → spellistan syns i listan som "inloggning saknas/synkas" tills hemligheten finns (hemlighet saknas = tydligt läge, inte krasch).
- [ ] **Step 1: Write failing tests:** `migrationV9ToV10AddsUpdatedAtAndKeepsOffsets`, `localNewerOffsetNotOverwritten`, `remoteOffsetStoredWithoutFiles`, `remoteOnlyPlaylistShowsMissingCredentialsState`, `removedPlaylistLeavesTombstone`; `MigrationTests` v1…v10.
- [ ] **Step 2–4:** CI → implementera → grönt. **Step 5: Commit** `feat(sync): textförskjutningar och spellistmetadata i synkbart format (v10)`.

---

### Task 5: SyncCoordinator och tillgänglighet (utan CloudKit)

**Files:**
- Create: `Apps/Shared/Sync/{SyncCoordinator,SyncAvailability}.swift`
- Modify: `Apps/Shared/AppModel.swift`, `Apps/Shared/Profiles/ProfileSession.swift`, store-wrappers (ändringsnotiser), `Apps/Config/Base.xcconfig` + `iOSAppInfo.plist`/`AppInfo.plist` (`ICLOUD_SYNC_ENABLED` → Info.plist-nyckel `SyncEnabled`, standard `NO`)
- Test: `Apps/SharedTests/SyncCoordinatorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum SyncAvailability { static func isAvailable(bundle: Bundle) -> Bool }     // Info.plist SyncEnabled == YES
  @MainActor @Observable final class SyncCoordinator {
      enum Status: Equatable { case unavailable, off, idle(lastSync: Date?), syncing, failed(SyncFailure) }   // SyncFailure: noAccount, offline, quota, other
      init(transport: (any SyncTransport)?, clock: SyncClock, defaults: UserDefaults, ...)
      var isEnabled: Bool { get }; func setEnabled(_ on: Bool) async; func syncNow() async; func noteLocalChange(_ id: SyncRecordID)
      var initialPullDone: Bool { get }          // används av ensureDefaultProfile
  }
  ```
  Beteende: ingen transport ⇒ `.unavailable` och alla metoder no-op; lokala ändringar → smutsiga poster → stryps (≤ var 60 s, direkt vid app→bakgrund/spelare stängs) → `push`; `remoteChanges`/start/foreground → `fetchChanges` → `apply` (huvudtråden bara för tillämpning, ingen I/O); felfall behåller smutsiga poster med exponentiell backoff; första aktivering gör full uppladdning + hämtning. **`ensureDefaultProfile` väntar på `initialPullDone` när synk är på** (max 10 s timeout, därefter normalt beteende). Avstängning slutar synka men raderar inget lokalt eller i molnet.
- [ ] **Step 1: Write failing tests:** `unavailableBuildIsCompleteNoOp` (ingen transport → ingen skillnad i beteende), `localChangesAreThrottledAndPushed`, `remoteChangeAppliesAndUpdatesUI`, `failedPushRetriesWithBackoff`, `noDuplicateDefaultProfileOnFreshDeviceWithSyncedProfiles`, `defaultProfileCreatedAfterTimeoutIfCloudEmpty`, `disablingStopsSyncWithoutDeletingData`, `echoOfRemoteApplyIsNotPushedBack`, `syncAvailabilityFalseWithoutInfoPlistFlag`.
- [ ] **Step 2–4:** CI → implementera → grönt. **Step 5: Commit** `feat(sync): SyncCoordinator med strypning, backoff och tillgänglighetsgrind`.

---

### Task 6: CloudKit-transport och build-/entitlementsgrind

**Files:**
- Create: `Packages/IPTVPlatform/Sources/Sync/{CloudKitTransport,CKRecordCoding}.swift` (ny target `Sync` i IPTVPlatform eller i `Library`; importerar `CloudKit`), `Apps/Config/{Sync.xcconfig,Sync.entitlements}`
- Modify: `Apps/project.yml` (`CODE_SIGN_ENTITLEMENTS = $(SYNC_ENTITLEMENTS)` från Base.xcconfig, standard tomt; Sync.xcconfig sätter `ICLOUD_SYNC_ENABLED=YES` och `SYNC_ENTITLEMENTS=Config/Sync.entitlements`), `Apps/Config/Base.xcconfig` (`#include? "Sync.xcconfig"` efter Secrets), `.gitignore` om behövs
- Test: `Packages/IPTVPlatform/Tests/SyncTests/CKRecordCodingTests.swift`

**Interfaces:**
- Produces: `CloudKitTransport: SyncTransport` via `CKSyncEngine` (privat databas, zon `iptv`, container `iCloud.se.sjodin.iptv`, recordType `SyncRecord` med fälten `kind, key, payload(Data), updatedAt, deleted, origin`; stora/okända fält ignoreras; tokens sparas i `Application Support`; kontostatus → `SyncFailure.noAccount`; `CKError.quotaExceeded`/`networkUnavailable` mappas). `CKRecordCoding`: ren `SyncRecord` ↔ fält-ordbok (testas utan CloudKit-container). **Standardbygget refererar varken entitlements eller skapar CKContainer** (koordinatorn får `transport: nil`).
- Ruling (planen): `Sync.xcconfig` är gitignorerad-lik mallfil (`Sync.xcconfig.template` incheckad) så att fri sideload fortsätter fungera; entitlementsfilen ligger i repot men refereras bara när `SYNC_ENTITLEMENTS` är satt.
- [ ] **Step 1: Write failing tests:** `ckRecordCodingRoundTripsAllKinds`, `unknownFieldsAreIgnored`, `payloadNeverContainsSecretsFieldNames`, `recordIDStableFromKindAndKey`, `defaultBuildHasNoEntitlementsReference` (läser genererad `Info.plist`/build-setting via XcodeGen-spec i testet om möjligt, annars README-kontroll i review).
- [ ] **Step 2–4:** CI grönt (kompilering av CloudKit-koden på simulator utan signering krävs). **Step 5: Commit** `feat(sync): CloudKit-transport bakom build-flagga och valfria entitlements`.

---

### Task 7: iCloud Keychain för inloggningar och PIN (opt-in)

**Files:**
- Modify: `Packages/IPTVPlatform/Sources/Secrets/{KeychainCredentialStore,KeychainProfilePinStore}.swift`, `Packages/IPTVKit/Sources/Core/CredentialStore.swift` (protokoll oförändrat om möjligt)
- Test: `Packages/IPTVPlatform/Tests/SecretsTests/KeychainSyncTests.swift`

**Interfaces:**
- Produces: `init(service:, synchronizable: Bool)`; synkroniserbara objekt använder `kSecAttrSynchronizable = true`, läsning/sökning/radering med `kSecAttrSynchronizableAny`; `func migrateToSynchronizable()` (läs lokalt → skriv synk → verifiera → ta bort lokal kopia) och `func stopSynchronizing(deleteCloudCopy: Bool)` (skriver lokal kopia först; **raderar iCloud-kopian bara när `deleteCloudCopy == true`**, annars lämnas den); `allPlaylistIDs()` täcker båda. Aldrig `ThisDeviceOnly`. Inga hemligheter i fel/loggar (befintlig redigeringsdisciplin).
- [ ] **Step 1: Write failing tests (testservice, simulator):** `synchronizableItemRoundTrips`, `readFindsBothLocalAndSyncedItems`, `migrationKeepsSecretReadableThroughout` (aldrig tomt mellanläge), `stopSyncingWithoutDeleteKeepsCloudCopy`, `stopSyncingWithDeleteRemovesBoth`, `errorsNeverContainSecret`, `pinHashSyncsOnlyWhenEnabled`. (Om simulatorns Keychain inte stödjer synkroniserbara objekt: markera med tydlig `.disabled("…")` och notera i ledgern – verifieras då på enhet.)
- [ ] **Step 2–4:** CI → implementera → grönt. **Step 5: Commit** `feat(secrets): valfri iCloud Keychain-synk för inloggningar och PIN`.

---

### Task 8: Inställningar för iCloud, borttagningar och koppling i appen

**Files:**
- Create: `Apps/Shared/Sync/SyncSettingsView.swift`
- Modify: `Apps/Shared/Settings/SettingsView.swift`, `Apps/Shared/AppModel.swift` (`purgeProfile`/spellistborttagning skapar gravstenar, anropar `noteLocalChange`), `Apps/Shared/Localizable.xcstrings`
- Test: `Apps/SharedTests/SyncSettingsModelTests.swift`

**Interfaces:**
- Produces: sektionen "iCloud" i Inställningar (iOS + tvOS): omkopplare **Synka med iCloud** (avstängd och förklarad när `unavailable`: "Kräver en build med iCloud (utvecklarkonto)"), status (senast synkad, fel med vanlig text: ingen iCloud-inloggning/offline/fullt), **Synka nu**, separat omkopplare **Synka inloggningar via iCloud Keychain** med tydlig varning (innehåller lösenord; stänga av frågar "Ta bort från iCloud också?" med två val), förklaring av vad som synkas/inte synkas. Profilborttagning/spellistborttagning skriver gravstenar (profil + barnposter) och synkas; PIN krävs som tidigare för borttagning av spellista.
- [ ] **Step 1: Write failing tests:** `unavailableBuildDisablesToggleWithExplanation`, `statusTextForEveryFailure`, `profileDeletionCreatesTombstonesForChildren`, `playlistRemovalTombstoneSyncs`, `turningOffKeychainSyncAsksAboutCloudCopy`, `kidsProfileCannotChangeSyncSettings` (barnprofil ser inte inställningen).
- [ ] **Step 2–4:** CI → implementera → grönt. **Step 5: Commit** `feat(sync): iCloud-inställningar, status och gravstenar vid borttagning`.

---

### Task 9: TestFlight-jobb, dokumentation, avslut

**Files:**
- Create: `.github/workflows/testflight.yml`
- Modify: `README.md` (avsnitt "Aktivera iCloud-synk och TestFlight" + "Testlista fas 7 (två riktiga enheter)"), ev. `.gitleaks.toml` (inga ändringar förväntas)
- Test: ingen enhetstest; `xcodebuild archive`-kontroll i workflow (dry run)

**Interfaces:**
- Produces: `testflight.yml` (trigger: `workflow_dispatch` med `dryRun`-ingång samt taggar `v*`; runner `xcode-27`). Första steget `gate` sätter `enabled=true` bara om `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `APPLE_TEAM_ID` finns; annars skrivs en notis och övriga steg hoppas över (jobbet blir grönt) – **TestFlight slås på enbart genom att lägga till secrets**. Steg: skriv `Secrets.xcconfig` + `Sync.xcconfig` (`ICLOUD_SYNC_ENABLED=YES`, `SYNC_ENTITLEMENTS`, `DEVELOPMENT_TEAM`), `CURRENT_PROJECT_VERSION = github.run_number`, `xcodebuild archive` (iOS + tvOS, automatisk signering med `-allowProvisioningUpdates -authenticationKeyPath/-ID/-IssuerID`), `-exportArchive` med ExportOptions (`method: app-store-connect`, `destination: upload`), nycklar rensas efter jobbet. `dryRun` kör bara osignerade arkiv (`CODE_SIGNING_ALLOWED=NO`) för att bevisa att arkivkonfigurationen bygger; kör den en gång manuellt och verifiera grönt.
- README-checklista (Aktivera): 1) betalt Apple Developer-konto, 2) skapa app-ID:n `se.sjodin.iptv.ios`/`.tv` med iCloud/CloudKit-kapabilitet och container `iCloud.se.sjodin.iptv`, 3) App Store Connect API-nyckel, 4) GitHub-secrets (lista), 5) `Sync.xcconfig` lokalt från mallen, 6) deploya CloudKit-schemat från utveckling till produktion. Testlista fas 7: två enheter synkar profil/historik/Min lista/betyg/inställningar; position längst kommen; radera profil på A försvinner på B; offline-enhet återuppväcker inget; ny enhet får inga dubbla profiler; Keychain-synk av/på inkl. "ta bort från iCloud"; gratis-sideload-bygget fungerar oförändrat; barnprofil/PIN; flygplansläge-återhämtning. Kända begränsningar (CloudKit ej testat i CI, per-blob-LWW för inställningar, textfiler/nedladdningar synkas ej, simulatorns Keychain).
- [ ] **Step 1:** skriv workflow + README. **Step 2:** kör `dryRun` via `gh workflow run` (kräver ditt godkännande för att trigga; annars notera som ej körd). **Step 3:** Hela sviten grön lokalt och i CI (`apple`, `kit-tests`, `performance`, `secrets`). **Step 4: Commit** `docs: fas 7 testlista, TestFlight-jobb och aktiveringsguide`; öppna draft-PR `fas7-icloud-testflight`.

---

## Utanför denna plan

- Synk av nedladdningar, undertextfiler, OpenSubtitles-inloggning, PIN-lockout, katalogdata/EPG; delad familjesynk; Android/webb.
- Fältvis (i stället för blob-vis) sammanslagning av `PlaybackSettings`; CloudKit-schemaändringar efter första produktionsdeploy; kraschrapportering via MetricKit-uppladdning.
- Faktisk TestFlight-/CloudKit-verifiering på enhet (kräver utvecklarkontot; täcks av testlistan).

## Self-review (körd)

- **Spec §12:** CloudKit privat DB för profiler/historik/Min lista/betyg/inställningar (Task 2–6), Keychain-synk (7), stabila id:n + tidsstämplar (2, 3), "senaste skrivning per fält / position längst kommen" (1; inställningar blob-vis = noterad avvikelse). **§3:** fungerar lokalt utan konto, gratis-signering orörd (5, 6), TestFlight "enbart genom secrets" (9), inga hemligheter i git/poster (3, 6, 7). **§10:** barnprofil/PIN (8), `isKids` synkas. **§13:** CI-jobb för TestFlight (9).
- **Typer:** `SyncRecord/SyncRecordID/SyncKind/SyncMerge` (1) används oförändrade i 3, 5, 6; `SyncTransport` (3) i 5, 6; `SyncCoordinator.initialPullDone` (5) i `ensureDefaultProfile`; `SyncFailure` (5) i 8.
- **Review Focus:** gravstenar/uppståndelse (1, 3), dubbla profiler (5), gratis-signering/krasch (5, 6), hemligheter/Keychain-radering (3, 7, 8), skrivförstärkning/konvergens (1, 3, 5) – varje rad har namngivna tester.
- **Proportion:** nio uppgifter; signaturer och testnamn utan kroppar.
