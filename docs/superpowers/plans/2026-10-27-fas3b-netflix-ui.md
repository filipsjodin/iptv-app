# Fas 3b: Netflix-upplevelsen på tvOS – Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hem på Apple TV där bakgrunden följer fokus, tyst förhandsvisning ur den egna strömmen, en hero-detaljsida enligt mockupen, snabb bildhantering och återhållsamma, systemnära animationer.

**Architecture:** Ren logik (fokus-stillastående, förhandsvisningens startpunkt och behörighet, kvalitetsmärken) ligger i `IPTVKit` så att den testas på Windows. Bilder går genom en gemensam pipeline (Nuke) med disk- och minnescache och förhämtning. En `PreviewController` i appen äger förhandsvisningens livscykel och tar sin anslutning från `StreamConnectionBroker` med lägsta prioritet (`.preview`), så att den aldrig tränger undan uppspelning eller nedladdning. tvOS får fokusdriven Hem; iOS behåller listlayouten från 3a men använder samma bildpipeline.

**Tech Stack:** SwiftUI (tvOS 27 fokusmotor, `.card`-stil), Nuke/NukeUI (bildcache), AVPlayer för förhandsvisning, GRDB-läsning via befintliga `MetadataStore`, Swift Testing, `os_signpost`.

**Spec:** `docs/superpowers/specs/2026-10-25-iptv-app-design.md` (§6.2, §6.3, §6.5, §9). Föregående plan: `docs/superpowers/plans/2026-10-26-fas3a-profiler-metadata.md` (klar, mergad).

## Global Constraints

- Plattformar: tvOS och iOS/iPadOS, lägsta version **27**. Swift 6 med strict concurrency, SwiftUI, `@Observable`.
- Prestandamål (§9): kallstart till interaktiv Hem < 1 s; **inga tappade bildrutor vid fokusbyte/scroll**; artwork redan i cache för synliga rader och ±1 skärm; förhandsvisning startar ≈ 1,5 s efter att fokus stannat.
- Ingen nätverksåtkomst eller databasskrivning på huvudtråden. `LazyHStack`/`LazyVStack` med stabila id:n. Inga dyra beräkningar i `body`.
- Animationer utgår från systemets fokusmotor och fjäderanimationer. **Inga egna "lekfulla" effekter** (anti-mål). Respektera Minska rörelse.
- Förhandsvisning (§6.5): ingen YouTube, ingen VLC; titelns egen ström tyst i AVPlayer cirka 10 % in (förtexter undviks, slutet avslöjas inte); serier använder S1E1. Reserv: bara artwork när strömmen inte kan spelas i AVPlayer (t.ex. MKV), förhandsvisningen inte startat inom ~3 s, anslutningen behövs till annat (`max_connections`) eller användaren stängt av förhandsvisningar. Strömmen stängs **omedelbart** när fokus flyttas.
- Inställningar per profil: förhandsvisningar på/av och ljud i förhandsvisningar på/av.
- Barnprofil: samma åldersfilter överallt (fail closed). Ingen förhandsvisning av titlar som inte klarar filtret.
- Publikt repo: inga nycklar, URL:er eller uppgifter i git. Nuke läggs till med fast version (≥ 2 veckor gammal).
- Svenska och engelska UI-texter via `Localizable.xcstrings`.
- På Apple skrivs `Core.Category`. Lägg inte explicita Library/GRDB/PlaybackTestSupport-beroenden på `IPTV-iOSTests`. Undvik `as AnyObject` i `#expect` (kompilatorkrasch).

## Review Focus

1. **Snabb fokusändring (zappande genom en rad):** inga förhandsvisningar startas eller läcker anslutningar; varje avbruten start släpper sin lease (test i Task 4/5: 20 fokusbyten på 1 s ger 0 aktiva leaser efteråt).
2. **Spellista med max_connections = 1 medan något spelas/laddas ner:** ingen förhandsvisning, artwork i stället, och ingen `onRevoke` mot uppspelningen (Task 4).
3. **Titel utan TMDB-match, utan backdrop eller utan logga:** Hem och detalj faller tillbaka till leverantörens affisch/titeltext utan tomma ytor eller krasch (Task 2/3/6).
4. **Barnprofil:** hero, förhandsvisning och detaljsida visar/spelar aldrig titlar utan känd åldersgräns ≤ 11 (Task 4/5).
5. **Minska rörelse / förhandsvisningar avstängda:** inga crossfades till video, ingen ljudstart; artwork-läge fungerar fullt ut (Task 5/7).

---

## Filstruktur

- `Packages/IPTVKit/Sources/Core/QualityBadges.swift` (ny): tolka kvalitetstaggar ur titel/container.
- `Packages/IPTVKit/Sources/PlaybackCore/PreviewPlan.swift` (ny): startpunkt, behörighet, fokus-stillastående.
- `Packages/IPTVKit/Sources/PlaybackCore/Settings.swift`: `previewSoundEnabled`.
- `Apps/Shared/DesignSystem/` (ny): `Motion.swift` (fjäderkonstanter, rörelse-medveten), `ArtworkImage.swift`, `ArtworkPipeline.swift`, `QualityBadgeRow.swift`, `RatingsRow.swift`.
- `Apps/Shared/Hero/` (ny): `HeroModel.swift`, `HeroBackdrop.swift`, `HeroInfoPanel.swift`, `PreviewController.swift`, `PreviewSurface.swift`.
- `Apps/Shared/HomeView.swift`, `Apps/Shared/Detail/*.swift`, `Apps/Shared/AppModel+Discovery.swift`, `Apps/Shared/AppModel+Hero.swift` (ny).
- `Apps/project.yml`: Nuke-paket.
- Tester: `Packages/IPTVKit/Tests/...`, `Apps/SharedTests/HeroTests.swift`, `PreviewControllerTests.swift`, `ArtworkPipelineTests.swift`.

---

### Task 1: Bildpipeline och designsystem-grund

**Files:**
- Modify: `Apps/project.yml` (paketet Nuke `12.8.0`, produkterna `Nuke` och `NukeUI` till båda apparna), `Apps/Shared/HomeView.swift`, `Apps/Shared/ContinueWatchingRow.swift`, `Apps/Shared/Detail/*.swift` (byt `AsyncImage`).
- Create: `Apps/Shared/DesignSystem/ArtworkPipeline.swift`, `ArtworkImage.swift`, `Motion.swift`.
- Test: `Apps/SharedTests/ArtworkPipelineTests.swift`.

**Interfaces:**
- Produces:
  - `enum ArtworkKind { case poster, backdrop, logo, still }` med `var tmdbSize: TMDBImage.Size` (poster `w342`, backdrop `w1280`, logo `w342`, still `w780`).
  - `struct ArtworkPipeline` (`@MainActor` fasad över Nuke): `static let shared`, `func prefetch(_ urls: [URL])`, `func cancelPrefetch(_ urls: [URL])`, `func isCached(_ url: URL) -> Bool`. Konfigurerad med diskcache (≤ 500 MB, i Caches) och minnescache (≤ 150 MB), nedskalning till visningsstorlek.
  - `struct ArtworkImage: View` (`init(url: URL?, kind: ArtworkKind, placeholderSystemImage: String)`) som visar cachad bild utan fade-in när den redan finns i minnet, annars kort `.easeOut(duration: 0.18)`-fade.
  - `enum Motion` med `static let focus: Animation = .spring(response: 0.35, dampingFraction: 0.85)`, `static let crossfade: Animation = .easeInOut(duration: 0.4)` och `static func animation(_ a: Animation, reduceMotion: Bool) -> Animation?` (returnerar `nil` vid Minska rörelse).

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@Test func tmdbSizePerKind() { /* poster→w342, backdrop→w1280, logo→w342, still→w780 */ }
@Test func motionIsNilUnderReduceMotion() { /* Motion.animation(.focus, reduceMotion: true) == nil; false → ej nil */ }
@MainActor @Test func prefetchedURLReportsCached() async { /* in-memory ImageCache-stub: prefetch(url) → isCached(url) true; cancelPrefetch rör inte redan cachade */ }
@MainActor @Test func missingURLRendersPlaceholderWithoutRequest() { /* ArtworkImage(url: nil): ingen request registreras */ }
```

- [ ] **Step 2–4:** Implementera pipeline och byt alla `AsyncImage`-anrop. Pusha och kontrollera att CI går från RED till GREEN.
- [ ] **Step 5:** Commit: `feat(app): bildpipeline med Nuke, ArtworkImage och rörelsetokens`.

---

### Task 2: Kvalitetsmärken, hero-data och negativ affischcache

**Files:**
- Create: `Packages/IPTVKit/Sources/Core/QualityBadges.swift`, `Apps/Shared/AppModel+Hero.swift`, `Apps/Shared/DesignSystem/QualityBadgeRow.swift`, `RatingsRow.swift`.
- Modify: `Apps/Shared/AppModel+Discovery.swift` (cachar även träff-fria uppslag i `tmdbPosterURL`).
- Test: `Packages/IPTVKit/Tests/CoreTests/QualityBadgesTests.swift`, `Apps/SharedTests/HeroTests.swift`.

**Interfaces:**
- Produces:
  - `public enum QualityBadge: String, Sendable, CaseIterable { case uhd4K = "4K", dolbyVision = "Dolby Vision", hdr = "HDR", atmos = "Atmos", surround51 = "5.1" }` och `public enum QualityBadges { public static func parse(title: String, containerExtension: String?) -> [QualityBadge] }` (tolkar taggar som `4K`, `UHD`, `2160p`, `DV`/`DoVi`, `HDR10`, `Atmos`, `5.1`; skiftlägesokänsligt, ordnade enligt enumordningen, utan dubbletter).
  - `struct HeroInfo: Equatable, Sendable { kind, providerID, title, year, runtimeMinutes, certification, ratings: [TitleRating], overview, backdropURL: URL?, logoURL: URL?, badges: [QualityBadge] }`.
  - `AppModel.hero(for item: Library.LibraryItem, playlistID: UUID) async -> HeroInfo?`: metadata-läsning off-main, en post per `(playlistID, kind, providerID)` cachas (LRU 200). Saknas metadata, backdrop eller logga returneras ändå `HeroInfo` med leverantörens titel/affisch och `nil` för det som saknas. Barnprofil: `nil` om titeln inte klarar åldersfiltret.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@Test func parsesBadgesFromTitle() { /* "Film 2160p HDR10 Atmos 5.1" → [.uhd4K,.hdr,.atmos,.surround51]; "Plain" → [] ; "DoVi 4K" → [.uhd4K,.dolbyVision] */ }
@Test func parseIsCaseInsensitiveAndDeduplicated() { }
@MainActor @Test func heroFallsBackToProviderData() async { /* ingen metadata → HeroInfo med titel, logoURL nil, backdropURL nil */ }
@MainActor @Test func heroDeniedForKidsWhenUnrated() async { }
@MainActor @Test func unmatchedPosterLookupIsCachedNegatively() async { /* andra anropet gör ingen DB-läsning (räknande store) */ }
```

- [ ] **Step 2–4:** Pusha och kontrollera att CI går från RED till GREEN.
- [ ] **Step 5:** Commit: `feat: kvalitetsmärken och hero-data med reservvärden`.

---

### Task 3: Förhandsvisningens ren logik (startpunkt, behörighet, fokus-stillastående)

**Files:**
- Create: `Packages/IPTVKit/Sources/PlaybackCore/PreviewPlan.swift`
- Modify: `Packages/IPTVKit/Sources/PlaybackCore/Settings.swift` (`previewSoundEnabled`, standard `true`, äldre sparad data utan nyckeln avkodas som `true`)
- Test: `Packages/IPTVKit/Tests/PlaybackCoreTests/PreviewPlanTests.swift`

**Interfaces:**
- Produces:
  - `public enum PreviewPlan { public static func startSeconds(duration: Double?) -> Double }`: `duration` känd → `min(max(duration * 0.10, 60), duration * 0.30)` avrundat till hela sekunder; okänd → `120`.
  - `public enum PreviewEligibility { public static func decide(settingsEnabled: Bool, kidsAllowed: Bool, container: String?, playbackActive: Bool, leaseGranted: Bool) -> PreviewDecision }` med `enum PreviewDecision: Equatable { case play, artwork(reason: PreviewFallback) }` och `enum PreviewFallback { disabled, kidsDenied, unsupportedContainer, connectionBusy }`. AVPlayer-spelbara containrar: `mp4`, `m4v`, `mov`, `m3u8`, `ts`; `mkv`, `avi`, `webm` och okänt → `unsupportedContainer`. Ordning på orsaker: `disabled`, `kidsDenied`, `unsupportedContainer`, `connectionBusy` (`playbackActive || !leaseGranted`).
  - `public struct FocusSettleGate: Sendable { init(settle: Duration = .milliseconds(1500)) ; mutating func focus(_ id: String, at: ContinuousClock.Instant); func settledID(at: ContinuousClock.Instant) -> String? }`: ger id först när samma id haft fokus ≥ `settle`.
  - `PlaybackSettings.previewSoundEnabled: Bool`.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@Test func startSecondsTenPercentWithFloorAndCap() { /* 7200→720; 300→60 (golv 60, tak 90 nås ej); 100→30 (tak 30 % slår golvet) */ }
@Test func startSecondsUnknownDurationIs120() { }
@Test func eligibilityOrderAndContainers() { /* mkv→unsupported; mp4+playbackActive→connectionBusy; disabled vinner över allt; kidsDenied före container */ }
@Test func settleGateOnlyReportsAfterSettle() { /* 1,4 s → nil; 1,5 s → id; byte av id nollställer */ }
@Test func previewSoundDefaultsTrueForLegacyBlob() { /* avkoda gammal JSON utan nyckeln */ }
```

- [ ] **Step 2–4:** Kör `source scripts/swift-env.sh && cd Packages/IPTVKit && swift test` (RED → GREEN) och pusha.
- [ ] **Step 5:** Commit: `feat(playbackcore): förhandsvisningens plan, behörighet och fokusgrind`.

---

### Task 4: PreviewController (livscykel, broker, AVPlayer)

**Files:**
- Create: `Apps/Shared/Hero/PreviewController.swift`, `PreviewSurface.swift`
- Modify: `Apps/Shared/AppModel+Hero.swift` (`previewRequest(for:playlistID:)`)
- Test: `Apps/SharedTests/PreviewControllerTests.swift`

**Interfaces:**
- Consumes: `StreamConnectionBroker.acquire(.preview, playlistID:onRevoke:)`/`release`, `AVPlayerEngine`, `PreviewPlan`, `PreviewEligibility`, `PlaybackSettings`, `LibraryStore.locator(...)`, `AppModel.kidsRestricted`.
- Produces:
  - `@MainActor @Observable final class PreviewController` med `private(set) var state: PreviewState` (`.idle`, `.starting`, `.playing(engine)`, `.artwork(PreviewFallback?)`), `func focusChanged(to item: Library.LibraryItem?, playlistID: UUID)`, `func stop() async` och `func setSoundEnabled(_:)`.
  - `focusChanged`: stoppar **synkront** (ljud av, `state = .idle`) och startar stängning av föregående; startar nytt först efter `FocusSettleGate`-tid. Förhandsvisningen laddas med `engine.load(url:startAt: PreviewPlan.startSeconds(duration:))`; om `state` inte blivit `.playing` inom 3 s → `.artwork(nil)`, strömmen stängs och lease släpps. Leasen släpps först **efter** att motorn stängts (`closeAndWait`), aldrig före.
  - `onRevoke` (broker vill ha anslutningen): stäng direkt, `state = .artwork(.connectionBusy)`.
  - `PreviewSurface` (SwiftUI-vy) visar motorns video tyst och tonar in över backdropen med `Motion.crossfade` (ingen animation under Minska rörelse).

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@MainActor @Test func rapidFocusChangesLeaveNoActiveLeases() async { /* 20 focusChanged på 1 s med TestClock → efter sista stop: broker.activeCount == 0 */ }
@MainActor @Test func previewStartsOnlyAfterSettle() async { }
@MainActor @Test func playbackActiveOnOneConnectionAccountFallsBackToArtwork() async { /* limit 1 + aktiv playback-lease → .artwork(.connectionBusy); playback revokas inte */ }
@MainActor @Test func startTimeoutAfterThreeSecondsFallsBackAndReleasesLease() async { }
@MainActor @Test func leaseReleasedOnlyAfterEngineClosed() async { /* långsam stängning (FakeEngine) → release efter close */ }
@MainActor @Test func kidsDeniedTitleNeverRequestsStream() async { }
@MainActor @Test func previewsDisabledNeverAcquires() async { }
```

- [ ] **Step 2–4:** Pusha och kontrollera att CI går från RED till GREEN. Använd `FakeEngine`/`PlaybackTestSupport` och injicerbar klocka.
- [ ] **Step 5:** Commit: `feat(app): PreviewController med broker-lease och reserv till artwork`.

---

### Task 5: Fokusdriven Hem på tvOS

**Files:**
- Create: `Apps/Shared/Hero/HeroModel.swift`, `HeroBackdrop.swift`, `HeroInfoPanel.swift`
- Modify: `Apps/Shared/HomeView.swift` (tvOS-gren; iOS behåller listlayouten), `Apps/Shared/Detail/TitleExtras.swift`
- Test: `Apps/SharedTests/HeroTests.swift` (utökas)

**Interfaces:**
- Consumes: `AppModel.hero(for:playlistID:)`, `PreviewController`, `ArtworkPipeline`, `ArtworkImage`, `QualityBadgeRow`, `RatingsRow`, `Motion`.
- Produces:
  - `@MainActor @Observable final class HeroModel`: `private(set) var current: HeroInfo?`, `func focus(_ item: Library.LibraryItem?, playlistID: UUID)` (hämtar `HeroInfo` off-main, ignorerar svar från ersatt fokus), `func prefetchWindow(rows: [HomeRow], focusedRow: Int)` (förhämtar poster för synliga rader och ±1 skärm samt backdrop för fokuserad ±3 titlar).
  - tvOS-`HomeView`: helskärmsbackdrop bakom allt (`HeroBackdrop`: backdrop → förhandsvisning via `PreviewSurface` när `PreviewController.state == .playing`), `HeroInfoPanel` (logga eller titeltext, betyg, år, längd, `QualityBadgeRow`, kort beskrivning max 3 rader, knapparna Spela, Min lista, 👍 kopplade till `PersonalStore`) och raderna i nedre delen; kort med `.card`-stil (systemets parallax/lyft). Fokus på ett kort anropar `HeroModel.focus` och `PreviewController.focusChanged`.
  - Alla bildbyten korsar med `Motion.crossfade`; inga animationer vid Minska rörelse.
  - Topp 10-raderna visar stora siffror (1–10) bredvid affischen (systemtypografi, inga egna effekter).

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@MainActor @Test func lateHeroResponseForReplacedFocusIsIgnored() async { /* focus(A) långsam, focus(B) snabb → current == B */ }
@MainActor @Test func prefetchWindowCoversVisibleRowsPlusOneScreen() async { }
@MainActor @Test func heroPanelActionsWriteToPersonalStore() async { /* Min lista och 👍 från panelen → PersonalStore */ }
@MainActor @Test func homeWithoutMetadataShowsProviderFallbackHero() async { }
@MainActor @Test func reduceMotionDisablesCrossfade() async { }
```

- [ ] **Step 2–4:** Pusha och kontrollera att CI går från RED till GREEN. Lägg till signposts (`os_signpost`) runt `HeroModel.focus` och första rad-rendering så att Nightly kan mäta dem.
- [ ] **Step 5:** Commit: `feat(app): fokusdriven Hem med hero, förhandsvisning och förhämtning`.

---

### Task 6: Detaljsidan enligt mockupen (film och serie)

**Files:**
- Modify: `Apps/Shared/Detail/MovieDetailView.swift`, `SeriesDetailView.swift`, `TitleExtras.swift`, `Apps/Shared/Settings/SettingsView.swift` (förhandsvisning på/av och ljud på/av per profil), `Apps/Shared/Localizable.xcstrings`
- Test: `Apps/SharedTests/DiscoveryUITests.swift` (utökas)

**Interfaces:**
- Consumes: `HeroModel`/`HeroInfo`, `PreviewController`, `ProfileSession.settings` (`previewsEnabled`, `previewSoundEnabled`), befintlig `TitleDetail`.
- Produces:
  - Detaljsidans topp: backdrop med fortsatt förhandsvisning (samma `PreviewController`, ingen omstart om samma titel redan spelar), logga/titel, `RatingsRow`, år, genrer, åldersgräns, `QualityBadgeRow`, beskrivning, skådespelare i urval, regissör/skapare.
  - Knappar: "Spela" eller "Fortsätt S2:E4 · 32 min kvar" (beräknas ur `UserStateStore`), "Från början", Min lista, 👍 och 👎 (växlar; synligt valt tillstånd).
  - Serier: säsongsflikar, avsnitt i horisontell rad med stillbild (leverantörens), titel, längd, beskrivning och röd förloppslinje; sedda avsnitt markerade.
  - "Liknande titlar" startar parallellt med metadatahämtningen (`async let`) så att listan inte väntar på TMDB-timeout.
  - Inställningar: två växlare per profil som skriver till `ProfileSession.settings`.
  - Info-rutan (ljudspår/undertexter/video/spelare, §6.3) skjuts till fas 5 (OpenSubtitles) (kräver ström-probing); noteras i README.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@MainActor @Test func continueButtonShowsEpisodeAndRemainingTime() async { /* S2:E4, 32 min kvar */ }
@MainActor @Test func fromStartResetsResumePosition() async { }
@MainActor @Test func ratingToggleCyclesUpDownNone() async { }
@MainActor @Test func similarTitlesDoNotWaitForMetadataFetch() async { /* hängande metadata-stub → similar levereras ändå */ }
@MainActor @Test func previewSettingsPersistPerProfile() async { }
@MainActor @Test func detailWithoutBackdropOrLogoFallsBackWithoutBlankAreas() async { }
```

- [ ] **Step 2–4:** Pusha och kontrollera att CI går från RED till GREEN.
- [ ] **Step 5:** Commit: `feat(app): hero-detaljsida, sändningsknappar och förhandsvisningsinställningar`.

---

### Task 6b: Avsnittens stillbild, beskrivning och längd

Tillägg efter granskningen av Task 6 (spec §6.3 kräver stillbild, titel, längd, beskrivning och förloppslinje per avsnitt; `Core.Episode` saknar fälten).

**Files:**
- Modify: `Packages/IPTVKit/Sources/Core/Models.swift` (`Episode`), `Packages/IPTVKit/Sources/Providers/Xtream/XtreamDTO.swift` (`XtreamEpisodeDTO` avkodar `info`), `XtreamMapper.episodes`, `Packages/IPTVPlatform/Sources/Library/AppDatabase.swift` (ny migration), `LibraryStore.swift` (INSERT/SELECT), `Apps/Shared/Detail/SeriesDetailView.swift` (`EpisodeCardData`, `EpisodeCard`, `EpisodeShelf.stillURL(for:)`).
- Test: `XtreamClientTests` (+ fixtures), `LibraryStoreV2Tests`, `MigrationTests`, `Apps/SharedTests/DiscoveryUITests.swift`.

**Interfaces:**
- Produces: `Core.Episode` får `stillURL: URL?`, `overview: String?`, `durationSeconds: Int?` (alla med standardvärde `nil` i init, så befintliga anrop kompilerar). Xtream: `info.movie_image` → `stillURL`, `info.plot` → `overview`, `info.duration_secs` (annars tolkad `info.duration` som `HH:MM:SS`) → `durationSeconds`, med de befintliga toleranta wrapparna (siffra som sträng eller tal, saknat fält).
- DB: migration lägger till tre nullable kolumner på `episode`. Redan lagrade avsnitt saknar fälten; `model.episodes` hämtar om serien en gång när fälten saknas för en serie som lästs före migrationen (schema-stämpel, inte vid varje öppning).
- UI: avsnittskortet visar stillbild (`ArtworkImage` kind `.still`; reserv: tom ruta med ikon), titel, längd (nu känd direkt), beskrivning (högst 3 rader) och förloppslinje.

- [ ] **Step 1:** Skriv tester som misslyckas: Xtream-JSON med `info` ger fälten; saknat/felformat `info` ger `nil` utan fel; migrationen bevarar befintliga avsnitt och lägger kolumner; ett avsnitt utan fält triggar en enda omhämtning; kortet visar längd och beskrivning.
- [ ] **Step 2–4:** Pusha och kontrollera att CI går från RED till GREEN. Kör `swift test` lokalt för IPTVKit-delen.
- [ ] **Step 5:** Commit: `feat: avsnittens stillbild, beskrivning och längd`.

---

### Task 7: Skärpning från fas 3a och prestandamätning

**Files:**
- Modify: `Apps/Shared/PlaylistsView.swift` + `AppModel.swift` (borttagning av spellista), `Apps/Shared/AppModel+Discovery.swift` (live-vakt), `.github/workflows/nightly.yml`, `README.md`
- Test: `Apps/SharedTests/ProfileSessionTests.swift`, `Apps/SharedTests/AppModelPlaybackTests.swift`

**Interfaces:**
- Produces:
  - **Borttagning av spellista kräver vuxen-PIN** med samma regel som profilhantering (kräver PIN från en vuxenprofil i spellistan om någon har PIN; annars fri; blockerad när en barnprofil är aktiv). `AppModel.remove(playlistID:adultPin:)` kastar `ProfileError.adultPinRequired`/`wrongPin`/`notAllowed`.
  - `liveRequest` nekar när `kidsRestricted` (djupförsvar, fliken är redan dold).
  - Signposts `hero.focus`, `home.firstRows` och `preview.start` exponeras för Nightly; Nightly-jobbet loggar fokus→hero-latens på en genererad spellista (200 000 poster) och larmar över 100 ms (medel).
  - README: testlista fas 3b (nedan) och noteringen att info-rutan kommer i fas 5.

- [ ] **Step 1: Skriv tester som misslyckas**

```swift
@MainActor @Test func removingPlaylistNeedsAdultPinWhenOneExists() async { }
@MainActor @Test func removingPlaylistBlockedForKidsProfile() async { }
@MainActor @Test func liveRequestDeniedForKids() async { }
```

- [ ] **Step 2–4:** Pusha och kontrollera att CI går från RED till GREEN.
- [ ] **Step 5:** README, `gitleaks detect --config .gitleaks.toml` ska ge `no leaks found`; kontrollera att CI är grönt. Commit: `feat(app): vuxen-PIN för borttagning av spellista, live-vakt och prestandamätning`.

**Testlista fas 3b (riktig Apple TV, läggs i README):**
- Bläddra genom en rad med fjärrkontrollen: inga hack, bakgrunden byter mjukt.
- Stanna på en titel: efter cirka 1,5 s tonar förhandsvisningen in (tyst först, sedan ljud om inställningen tillåter). Flytta fokus: den stoppas direkt.
- Titel i MKV eller konto med en anslutning som spelar: artwork visas i stället, ingen förhandsvisning.
- Stäng av förhandsvisningar/ljud i Inställningar: gäller bara aktiv profil.
- Detaljsida: Fortsätt-knappen visar rätt avsnitt och tid kvar; 👍/👎 och Min lista syns direkt.
- Barnprofil: ingen titel utan åldersgräns syns eller förhandsvisas.
- Slå på Minska rörelse: inga övertoningar till video.
- Kallstart till Hem under 1 s.

---

## Självgranskning

- **Spec-täckning:** §6.2 (bakgrund följer fokus, 1,5 s, raderna, Topp 10) → Task 5; §6.3 (knappar, säsongsflikar, liknande) → Task 6 (info-ruta uttryckligen skjuten); §6.5 (förhandsvisning, reserv, inställningar, omedelbar stängning) → Task 3–4; §9 (förhämtning, ±1 skärm, signposts) → Task 1, 5, 7; §10 (barnprofil) → Task 2, 4, 7. Sport är struket ur projektet (2026-10-31).
- **Typkonsistens:** `HeroInfo`, `PreviewController.focusChanged(to:playlistID:)`, `PreviewDecision`, `ArtworkKind` definieras en gång och används med samma namn i Task 4–6.
- **Proportion:** uppgifterna anger signaturer och testnamn, inte implementationer.
