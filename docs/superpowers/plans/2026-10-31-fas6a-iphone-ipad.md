# Fas 6a: iPhone och iPad – implementationsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iPhone och iPad får egna, adaptiva vyer (flikrad på iPhone, sidomeny på iPad, Sök-flik, affischgrid, hero på Hem, detaljsida utan automatisk förhandsvisning), samt AirPlay, Now Playing med fjärrkommandon i VLC-spelaren, liggande helskärm och anpassad live-zappning.

**Architecture:** Ingen ny modul. En ren layoutmodul (`LayoutMetrics`) avgör affischbredd och kolumner ur tillgänglig bredd (inte ur enhetstyp, så Split View/Slide Over blir rätt). Nya iOS-vyer lever i `Apps/Shared` bakom `#if !os(tvOS)` och återanvänder AppModel, `TitleDestination`, `PlayerPresentation` och `ArtworkImage`. Spelarsidan får en liten `NowPlayingController` och en AirPlay-knapp. Nedladdningar (spec §11) är **fas 6b** och ingår inte här.

**Tech Stack:** Swift 6, SwiftUI (`TabView` med `.sidebarAdaptable`, `LazyVGrid`, `ViewThatFits`), AVKit (`AVRoutePickerView`), MediaPlayer (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`), UIKit-brygga för orientering.

**Spec:** `docs/superpowers/specs/2026-10-25-iptv-app-design.md` (§3 plattformar, §6.1 navigation, §6.3 detaljsida, §6.4 iPhone och iPad, §6.5 förhandsvisning, §7.1 motorer, §9 prestanda, §10 profiler). Fas 4-planen (`2026-10-31-fas4-live-tv-epg.md`) och fas 5-planen beskriver `PlayerScreen`, `ZapController`, `LiveTabView` och undertextsystemet som återanvänds.

## Global Constraints

- Swift 6 strikt samtidighet; `@Observable`/`@MainActor` i UI; Swift Testing för tester.
- **tvOS får inte ändras i beteende.** All ny kod är `#if !os(tvOS)` eller delad kod med oförändrat tvOS-resultat. tvOS-bygget ska förbli grönt.
- Lägsta version iOS/iPadOS 27 [Beslutat]. Layout styrs av bredd/size class, aldrig av `UIDevice.idiom`.
- **iOS-navigation** [§6.1]: flikrad nederst med Hem, Filmer, Serier, Live TV, Sök (Nedladdningar kommer i 6b). iPadOS: sidomeny med samma innehåll. Live döljs för barnprofil.
- **Förhandsvisning** [§6.4]: detaljsidan har förhandsvisning eller artwork överst, men förhandsvisningen **startar inte automatiskt** vid scroll eller sidvisning på iPhone/iPad. Ingen förhandsvisning använder en `max_connections`-plats på iOS utan uttryckligt tryck.
- **Spelare** [§6.4, §7.1]: liggande helskärm, bild-i-bild (AVPlayer) och AirPlay. VLC har enligt §7.1 ingen bild-i-bild; AirPlay-video kräver AVPlayer, så VLC-spelaren visar i stället en tydlig knapp "Byt till Apples spelare" när användaren försöker AirPlay.
- **Barnprofil** [§10]: sök filtrerar på åldersgräns (`kids:`), Live-fliken saknas, och ingen ny vy får nå Live, konto eller undertextsökning för barn.
- Prestanda [§9]: lata staplar/grid med stabila id:n, inget dyrt i `body`, ingen nätverks-, fil- eller databasåtkomst på huvudtråden, affischer via `ArtworkImage`.
- **Inga hemligheter** i repot, loggar, fixtures eller commit. Titel (men aldrig URL, token eller spellistans uppgifter) får visas i Now Playing.
- Svenska i commit-meddelanden; trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Nya UI-strängar i `Localizable.xcstrings` (engelska nycklar, svensk översättning; giltig JSON).
- Apple-kod verifieras bara i CI (eller på Macen); ren logik placeras där den kan testas (`IPTVKit` lokalt med `source scripts/swift-env.sh && cd Packages/IPTVKit && swift test`). **Per-fil-import-revision** före varje commit av Apple-kod (saknade `import Core/Providers/PlaybackCore/Library`; `Library.LibraryItem` kvalificeras). Testfiler med globala hjälpare som rör `@MainActor`-tillstånd markeras `@MainActor`; globala closures är `@Sendable` (två CI-fel i fas 5).
- Subagenter: bara `model: sonnet`; Opus bara efter verklig fastkörning, noterat i ledgern.

## Review Focus

1. **Barnprofil i Sök-fliken:** titlar utan godkänd åldersgräns får aldrig visas, varken som träff eller via förslag; Live-fliken och dess sidomenypost saknas. Task 1.
2. **Smal bredd (iPad Split View/Slide Over, stor Dynamic Type, iPhone SE):** inga avklippta affischer eller överlappande knappar; kolumnantal räknas om vid breddändring. Task 2, 3.
3. **Rotation mitt i uppspelning och i bild-i-bild:** positionen, vald undertext och zappningen bevaras; spelaren tvingar inte fast orientering efter stängning. Task 6.
4. **Motorbyte AVPlayer ↔ VLC med AirPlay/Now Playing aktivt:** Now Playing ägs av rätt motor, rensas bara av ägaren, och fjärrkommandon pekar aldrig på en stoppad motor. Task 5.
5. **Avbrott (samtal, Siri, hörlursurkoppling):** VLC pausar och Now Playing visar pausad; uppspelning återupptas bara på användarens kommando. Task 5.
6. **Automatisk förhandsvisning på iOS:** får aldrig starta av sig själv och aldrig ta en anslutning. Task 4.
7. **VoiceOver:** affischer i grid har titel som etikett, Sök-träffar är grupperade (Filmer/Serier), AirPlay-knappen har etikett. Task 2, 3, 5.

---

## File Structure

| Fil | Ansvar |
|---|---|
| `Packages/IPTVKit/Sources/PlaybackCore/LayoutMetrics.swift` (ny) | ren layoutberäkning (affischbredd, kolumner) |
| `Packages/IPTVKit/Sources/PlaybackCore/PreviewPolicy.swift` (ny) | ren regel när förhandsvisning får starta |
| `Packages/IPTVKit/Sources/PlaybackCore/NowPlayingInfo.swift` (ny) | ren modell för elapsed/duration/rate/live → tal och tillstånd |
| `Apps/Shared/LibraryBrowserView.swift` | adaptiv `TabView`, Sök-flik, gridlista för Filmer/Serier på iOS |
| `Apps/Shared/Search/SearchTabView.swift`, `SearchModel.swift` (nya) | global sökning över filmer och serier (iOS) |
| `Apps/Shared/PosterGridView.swift` (ny) | `LazyVGrid` av `PosterCard` med `LayoutMetrics` |
| `Apps/Shared/HomeView.swift`, `Apps/Shared/Hero/IOSFeaturedBanner.swift` (ny) | Hem på iOS med featured-banner och adaptiva hyllor |
| `Apps/Shared/Detail/*` | artwork överst, ingen autostart på iOS |
| `Apps/Shared/Player/AirPlayButton.swift`, `NowPlayingController.swift` (nya), `VLCPlayerHost.swift`, `PlayerScreen.swift`, `PlayerControlsOverlay.swift` | AirPlay, Now Playing, fjärrkommandon |
| `Apps/Shared/Player/PlayerOrientation.swift` (ny) | liggande helskärm och återställning |
| `Apps/Shared/Live/LiveTabView.swift`, `ChannelSwitcherSheet.swift` (ny) | iPad delad vy, kanalbytarblad i spelaren |
| `.github/workflows/ci.yml` | iPad-simulatorbygge |
| `README.md` | testlista "Fas 6a på riktig iPhone/iPad" |

---

### Task 1: Adaptiv navigation och Sök-flik

**Files:**
- Modify: `Apps/Shared/LibraryBrowserView.swift` (iOS: `.tabViewStyle(.sidebarAdaptable)`, ny `Tab("Search", systemImage: "magnifyingglass", value: .search, role: .search)`)
- Create: `Apps/Shared/Search/SearchModel.swift`, `Apps/Shared/Search/SearchTabView.swift` (båda `#if !os(tvOS)`)
- Test: `Apps/SharedTests/SearchModelTests.swift`

**Interfaces:**
- Consumes: `DiscoveryService.search(_:playlistID:kind:limit:kids:)` med `kind: nil`, `AppModel.discovery`, `AppModel.kidsRestricted`, `offMain`, `TitleDestination`, `PosterCard`.
- Produces:
  ```swift
  @MainActor @Observable final class SearchModel {
      init(playlistID: UUID, search: @escaping @Sendable (String, Bool) async throws -> [Library.LibraryItem], kids: @escaping @MainActor () -> Bool)
      enum Phase: Equatable { case idle, searching, results(movies: [Library.LibraryItem], series: [Library.LibraryItem]), empty, failed }
      var query: String { get set }
      var phase: Phase { get }
      func queryChanged() async     // 150 ms debounce, avbryter föregående, tomma frågor → .idle
  }
  ```
  Live-poster ingår aldrig i träffarna (bara `.movie` och `.series`).

- [ ] **Step 1: Write failing tests** (`search` är en mock som räknar anrop och spelar in `kids`-flaggan): `emptyQueryIsIdleAndDoesNotSearch`, `resultsAreSplitIntoMoviesAndSeries` (live filtreras bort), `kidsFlagIsPassedToSearch`, `kidsFlagIsReReadAfterAwait` (profil byts till barn medan sökningen pågår → träffar kastas och fasen blir `.empty`), `newQueryCancelsPreviousSearch` (inget gammalt resultat skriver över), `noResultsGivesEmpty`, `failureGivesFailed`.
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement** `SearchModel` och `SearchTabView` (`NavigationStack` med `.searchable`, två sektioner Filmer/Serier som `PosterGridView`-sektioner när Task 2 finns, annars `ItemRow`; tom- och felvy). I `LibraryBrowserView`: iOS får sök-fliken sist i `.sidebarAdaptable`; `LibrarySection.search`; Live-fliken döljs som förut för barn. tvOS-grenen ändras inte.
- [ ] **Step 4:** CI grönt (`apple`).
- [ ] **Step 5: Commit** `feat(ios): sidomeny på iPad och global Sök-flik`.

---

### Task 2: Layoutmått och affischgrid

**Files:**
- Create: `Packages/IPTVKit/Sources/PlaybackCore/LayoutMetrics.swift`, `Apps/Shared/PosterGridView.swift`
- Modify: `Apps/Shared/HomeView.swift` (`PosterCard.width`, `TitleShelf` använder metrics på iOS), `Apps/Shared/LibraryBrowserView.swift` (`ItemListView` blir `PosterGridView` på iOS, med oförändrad sidning), `Apps/Shared/Search/SearchTabView.swift`
- Test: `Packages/IPTVKit/Tests/PlaybackCoreTests/LayoutMetricsTests.swift` (lokalt)

**Interfaces:**
- Produces:
  ```swift
  public struct LayoutMetrics: Sendable, Equatable {
      public init(availableWidth: Double, dynamicTypeScale: Double = 1)
      public var posterWidth: Double { get }      // smalast 100, bredast 180
      public var columns: Int { get }              // minst 2
      public var spacing: Double { get }
      public var isRegular: Bool { get }           // availableWidth ≥ 700
  }
  ```
  Regler: `columns = max(2, floor((availableWidth − 2·16 + spacing) / (target + spacing)))`, där målbredden är 110 vid bredd < 430, 130 vid 430–700, 150 därefter; `posterWidth` fyller kolumnen och klampas till 100…180; stor Dynamic Type (`dynamicTypeScale > 1.3`) ger en kolumn färre (dock minst 2).

- [ ] **Step 1: Write failing tests:** `iPhonePortraitGetsThreeOrFourColumns` (bredd 390 → 3), `iPadFullWidthGetsManyColumns` (1024 → ≥ 6), `narrowSplitViewKeepsAtLeastTwoColumns` (320 → 2), `posterWidthIsClamped`, `largeDynamicTypeRemovesOneColumn`, `isRegularThreshold`, `zeroOrNegativeWidthDoesNotCrash` (→ 2 kolumner).
- [ ] **Step 2: Run** `swift test --filter LayoutMetricsTests` → FAIL.
- [ ] **Step 3: Implement** `LayoutMetrics`. `PosterGridView(items:, playlistID:, onAppearLast:)` läser bredden med `onGeometryChange` (inte `GeometryReader` i `body`-hot path) och bygger `LazyVGrid` med `GridItem(.adaptive...)` ersatt av `columns` från `LayoutMetrics`; `PosterCard` tar bredd som parameter (standardvärdet oförändrat för tvOS). Etikett för VoiceOver = titel. Sidningen (`loadMore` vid sista) flyttas oförändrad till gridens sista cell.
- [ ] **Step 4:** Lokala tester gröna; CI grönt.
- [ ] **Step 5: Commit** `feat(ios): adaptiv affischgrid för Filmer, Serier och Sök`.

---

### Task 3: Hem på iPhone och iPad

**Files:**
- Create: `Apps/Shared/Hero/IOSFeaturedBanner.swift` (`#if !os(tvOS)`)
- Modify: `Apps/Shared/HomeView.swift` (`ListHomeView`: banner överst, hyllor med `LayoutMetrics`), `Apps/Shared/Localizable.xcstrings`
- Test: `Apps/SharedTests/FeaturedBannerModelTests.swift`

**Interfaces:**
- Consumes: `AppModel.homeRows(playlistID:)`, `HomeRow`, `AppModel.tmdbPosterURL`/backdrop-API från `AppModel+Hero` (läs hur `HeroModel` hämtar backdrop och logga), `ArtworkImage`, `TitleDestination`.
- Produces:
  ```swift
  struct FeaturedPick: Equatable { var item: Library.LibraryItem }
  enum FeaturedPicker { static func pick(from rows: [HomeRow]) -> FeaturedPick? }   // första titeln i "För dig", annars första i första raden som inte är Fortsätt titta; aldrig live
  ```
  Bannern visar backdrop (artwork, ingen video), titel, betyg/år/kvalitetsmärken som `HeroInfoPanel` redan visar om det går att återanvända, och knapparna Spela och Mer info (öppnar detaljsidan). Stor bredd (iPad): banner 21:9 och hyllor med större affischer; smal: banner 16:9.

- [ ] **Step 1: Write failing tests:** `picksFirstForYouTitle`, `fallsBackToFirstNonContinueRow`, `skipsEmptyRowsAndLive`, `nilWhenNoRows`, `kidsRowsOnlyContainAllowedTitles` (väljaren väljer bara ur raderna den får, som redan är åldersfiltrerade).
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement** väljaren och bannern. Bannern laddar sin backdrop via samma pipeline som tvOS-hero (ingen ny nätverkskod i `body`), och tas inte fram för barnprofil om raden är tom. Pull-to-refresh läser om raderna (`generation += 1`).
- [ ] **Step 4:** CI grönt.
- [ ] **Step 5: Commit** `feat(ios): Hem med featured-banner och adaptiva hyllor`.

---

### Task 4: Detaljsidan på iOS utan autostart

**Files:**
- Create: `Packages/IPTVKit/Sources/PlaybackCore/PreviewPolicy.swift`
- Modify: `Apps/Shared/Detail/MovieDetailView.swift`, `SeriesDetailView.swift`, `TitleDetailScreen.swift`, `Apps/Shared/Hero/PreviewController.swift` (bara om autostart sker där)
- Test: `Packages/IPTVKit/Tests/PlaybackCoreTests/PreviewPolicyTests.swift` (lokalt), `Apps/SharedTests/DetailPreviewTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum PreviewPlatform: Sendable { case tv, handheld }
  public struct PreviewPolicy: Sendable {
      public static func autoStartsOnAppear(_ platform: PreviewPlatform) -> Bool          // .tv → true, .handheld → false
      public static func allowsUserStartedPreview(_ platform: PreviewPlatform, previewsEnabled: Bool, kids: Bool) -> Bool
  }
  ```
  På iOS visar detaljsidan artwork/backdrop överst med en tydlig knapp "Förhandsvisa" (ikon, tyst start) som är den enda vägen till en förhandsvisning och bara visas när `allowsUserStartedPreview`. Hemmets förhandsvisning (tvOS) berörs inte.

- [ ] **Step 1: Write failing tests:** `handheldNeverAutoStarts`, `tvAutoStarts`, `userStartedPreviewRequiresSettingAndNotKids`, och i appen `iOSDetailDoesNotStartPreviewOnAppear` (testad via den modell som idag startar förhandsvisningen: ingen `PreviewController`-start utan tryck).
- [ ] **Step 2: Run** `swift test --filter PreviewPolicyTests` → FAIL.
- [ ] **Step 3: Implement.** Hitta var detaljvyerna startar förhandsvisningen (`sharedPreview`/`PreviewController`), styr den med `PreviewPolicy`. På iOS: artwork överst (hero-bild + titellogga/text), Spela/Fortsätt, Min lista, 👍/👎 oförändrade; ljud av som standard. Förhandsvisningen stoppas direkt vid scroll bort eller när sidan lämnas (så att anslutningen aldrig hålls).
- [ ] **Step 4:** Lokala tester gröna; CI grönt.
- [ ] **Step 5: Commit** `feat(ios): detaljsida med artwork och förhandsvisning på tryck`.

---

### Task 5: AirPlay, Now Playing och fjärrkommandon

**Files:**
- Create: `Packages/IPTVKit/Sources/PlaybackCore/NowPlayingInfo.swift`, `Apps/Shared/Player/AirPlayButton.swift`, `Apps/Shared/Player/NowPlayingController.swift`
- Modify: `Apps/Shared/Player/VLCPlayerHost.swift` (ersätt `VLCNowPlaying` av `NowPlayingController`), `Apps/Shared/Player/PlayerScreen.swift` (`AVPlayerTopBar` får `AirPlayButton`), `Apps/Shared/Player/PlayerControlsOverlay.swift` (VLC: AirPlay-hint), `Apps/Shared/Localizable.xcstrings`
- Test: `Packages/IPTVKit/Tests/PlaybackCoreTests/NowPlayingInfoTests.swift` (lokalt), `Apps/SharedTests/NowPlayingControllerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct NowPlayingInfo: Sendable, Equatable {
      public init(title: String, elapsed: Double, duration: Double?, isPlaying: Bool, isLive: Bool)
      public var playbackRate: Double { get }          // 1 spelar, 0 pausad
      public var elapsedClamped: Double { get }        // ≥ 0, ≤ duration om känd
      public var durationForDisplay: Double? { get }   // nil för live eller okänd/≤ 0
  }
  @MainActor final class NowPlayingController {
      init(commands: NowPlayingCommands)               // protokoll över play/pause/togglePlayPause/skip/seek-ändringar
      func start(owner: ObjectIdentifier)
      func update(_ info: NowPlayingInfo, owner: ObjectIdentifier)
      func stop(owner: ObjectIdentifier)               // rensar bara om owner är den aktuella ägaren
  }
  struct AirPlayButton: UIViewRepresentable { ... }   // AVRoutePickerView, tintColor .white, tillgänglighetsetikett "AirPlay"
  ```
  Fjärrkommandon (Kontrollcenter, hörlurar, bilen): spela, pausa, växla, hoppa ±15 s, och byta position (`changePlaybackPositionCommand`) för VOD; för live bara spela/pausa. Titeln är den enda uppgiften utöver tid/hastighet (aldrig URL). Avbrott (`AVAudioSession.interruptionNotification`) pausar VLC och uppdaterar Now Playing; ingen automatisk återupptagning.

- [ ] **Step 1: Write failing tests:** lokalt `pausedHasRateZero`, `liveHasNoDuration`, `elapsedIsClampedToDuration`, `negativeElapsedIsZero`, `nonPositiveDurationIsNil`; i appen (mock av `NowPlayingCommands`) `stopByNonOwnerDoesNotClear`, `commandsAreRemovedOnStop`, `seekCommandDisabledForLive`, `interruptionPausesAndKeepsPosition`, `infoContainsOnlyTitleTimeAndRate` (inga URL:er).
- [ ] **Step 2: Run** `swift test --filter NowPlayingInfoTests` → FAIL.
- [ ] **Step 3: Implement.** AVPlayer sköter Now Playing själv (rör det inte). VLC-värden uppdaterar `NowPlayingController` vid start, paus, seek och var 5:e sekund, och rensar vid `onDisappear` bara som ägare (bevara det befintliga ägarskyddet). `AirPlayButton` visas i `AVPlayerTopBar` (AVPlayer). I VLC-kontrollerna visas i stället en ikonknapp som öppnar en förklaring "AirPlay-video kräver Apples spelare" med knappen "Byt till Apples spelare" (använder befintlig motorbytesåtgärd), och bara när motorbyte är tillåtet för titeln.
- [ ] **Step 4:** Lokala tester gröna; CI grönt.
- [ ] **Step 5: Commit** `feat(player): AirPlay, Now Playing och fjärrkommandon för VLC`.

---

### Task 6: Liggande helskärm och spelarlayout

**Files:**
- Create: `Apps/Shared/Player/PlayerOrientation.swift` (`#if !os(tvOS)`)
- Modify: `Apps/Shared/Player/PlayerScreen.swift`, `PlayerControlsOverlay.swift` (kontrollstorlekar och säkra områden), `Apps/iOS/iOSApp.swift` (orienteringsdelegat om det krävs)
- Test: `Apps/SharedTests/PlayerOrientationTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum PlayerOrientationPolicy {
      static func mask(isPlayerPresented: Bool, isPad: Bool) -> UIInterfaceOrientationMask   // iPhone i spelare: .landscape; iPad: .all; annars: .allButUpsideDown (iPhone) / .all (iPad)
  }
  @MainActor final class PlayerOrientationController {
      func playerWillAppear(); func playerDidClose()     // begär geometri via UIWindowScene.requestGeometryUpdate; återställer vid stängning
  }
  ```
  iPhone öppnar spelaren i liggande och återgår till stående när den stängs om enheten hålls stående; bild-i-bild, systemets helskärm och rotation mitt i uppspelning får inte starta om sessionen. Kontrollerna respekterar safe area (notch/Dynamic Island) och har minst 44 pt träffyta.

- [ ] **Step 1: Write failing tests:** `iPhonePlayerIsLandscapeOnly`, `iPadPlayerAllowsAllOrientations`, `closedPlayerRestoresPortraitCapableMask`, `controllerRestoresOnCloseEvenIfRequestFails`.
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement.** Delegat/`supportedInterfaceOrientationsFor` (SwiftUI-appdelegate-adapter om sådan saknas) läser policyn; `PlayerScreen` anropar kontrollern `onAppear`/`close()`; AVKits egna kontroller rörs inte.
- [ ] **Step 4:** CI grönt.
- [ ] **Step 5: Commit** `feat(player): liggande helskärm och säkra områden på iPhone`.

---

### Task 7: Live på iPad och kanalbytare i spelaren

**Files:**
- Create: `Apps/Shared/Live/ChannelSwitcherSheet.swift` (`#if !os(tvOS)`)
- Modify: `Apps/Shared/Live/LiveTabView.swift` (iPad/regular bredd: lista och tablå sida vid sida), `Apps/Shared/Player/PlayerMenus.swift` + `PlayerScreen.swift` (menyval "Kanaler"), `Apps/Shared/Live/EPGGridView.swift` (större celler och nu-linje vid regular bredd)
- Test: `Apps/SharedTests/ChannelSwitcherTests.swift`

**Interfaces:**
- Consumes: `LiveZapContext`, `ZapController` (`zap`, `current`, `cancel`, kanalgrupper), `LayoutMetrics.isRegular`.
- Produces:
  ```swift
  @MainActor @Observable final class ChannelSwitcherModel {
      init(groups: [ChannelGroup], currentID: String, select: @escaping @MainActor (ChannelGroup) -> Void)
      var sections: [ChannelSwitcherSection] { get }   // Favoriter, Senast sedda, alla; samma grupper och ordning som zapplistan
      var currentID: String { get }
      func choose(_ group: ChannelGroup)               // anropar select en gång, ignorerar redan vald kanal
  }
  ```
  Spelarmenyn får "Kanaler" bara för live med zapplista och utanför barnläge; valet byter kanal via samma `switchChannel` som zappning (stänger föregående ström först vid `max_connections` = 1). Svepzappningen och `ChannelInfoOverlay` finns redan; här läggs en haptisk bekräftelse och overlayn flyttas under safe area. På regular bredd visar Live-fliken kanallistan till vänster och tablån/programinfo till höger.

- [ ] **Step 1: Write failing tests:** `sectionsMatchZapListOrder`, `chooseCallsSelectOnce`, `chooseCurrentIsIgnored`, `switcherAbsentForKids` (menyposten saknas), `switcherAbsentWithoutZapContext`.
- [ ] **Step 2: Run** (CI) → FAIL.
- [ ] **Step 3: Implement.** Återanvänd `LiveModel`-data; inga nya databasanrop i `body`. iPad-delningen styrs av `LayoutMetrics.isRegular` från omgivande bredd.
- [ ] **Step 4:** CI grönt.
- [ ] **Step 5: Commit** `feat(live): iPad-layout och kanalbytare i spelaren`.

---

### Task 8: Verifiering, CI och dokumentation

**Files:**
- Modify: `.github/workflows/ci.yml` (extra steg: `xcodebuild build -scheme IPTV-iOS` mot en iPad-simulator), `README.md` (testlista), `project.yml` bara om en Info.plist-nyckel krävs
- Test: lokal kontroll av `LayoutMetrics`-svit; CI-jobb

**Interfaces:** Consumes: allt ovan.

- [ ] **Step 1:** Lägg till CI-steget (välj nyaste iPad-simulator som befintligt steg gör för iPhone; bygg bara, inga nya tester) och kontrollera att `iOSAppInfo.plist` fortfarande innehåller `UIBackgroundModes` = `audio`.
- [ ] **Step 2: README** "Testlista fas 6a på riktig iPhone/iPad": flikrad (iPhone) och sidomeny (iPad, kollapsar vid smal Split View); Sök-flik hittar filmer och serier, barnprofil ser inga olämpliga träffar; affischgrid sidar mjukt utan tomma rutor; Hem-banner; detaljsidan startar ingen förhandsvisning av sig själv; AirPlay från AVPlayer (TV/högtalare) och förklaringen i VLC; Kontrollcenter/hörlurar styr VLC; telefonsamtal pausar VLC; liggande helskärm och återgång vid stängning; rotation under uppspelning; bild-i-bild (AVPlayer) och att den inte tar fler anslutningar; kanalbytare och svepzappning i live; iPad: lista + tablå sida vid sida; stor textstorlek och VoiceOver på affischer.
- [ ] **Step 3:** Hela sviten grön lokalt (`swift test` i `IPTVKit`) och i CI (`apple`, `kit-tests`, `performance`, `secrets`).
- [ ] **Step 4: Commit** `docs: fas 6a testlista och iPad-bygge i CI`; öppna draft-PR `fas6a-iphone-ipad`.

---

## Utanför denna plan (fas 6b och senare)

- **Nedladdningar** (spec §11): `Downloads`-modul, bakgrunds-`URLSession`, köhantering mot `StreamConnectionBroker` (`StreamPurpose.download`), lagring av undertexter/artwork/metadata, offlineuppspelning, Nedladdningar-flik. Egen plan efter 6a så att erfarenheter från iOS-navigationen kan användas.
- M3U-fil från Filer (`fileImporter`) [Mitt beslut i spec §5]: kräver att `PlaylistSecret.m3u` kan peka på en lokal kopia; tas med när 6b rör spellistlagringen.
- Bild-i-bild för VLC (VLCKit saknar stöd, spec §7.1), EPG-sökning, backoff för EPG-hämtning.

## Self-review (körd)

- **Spec §6.1/§6.4:** flikrad, sidomeny och Sök-flik (Task 1), anpassade vyer (2, 3, 7), förhandsvisning startar inte automatiskt (4), liggande helskärm, bild-i-bild (befintlig, verifieras i testlistan) och AirPlay (5, 6). Nedladdningar och Nedladdningar-flik flyttade till 6b, uttryckligen listat.
- **Typer:** `LayoutMetrics.isRegular` används i Task 3 och 7; `PreviewPolicy`, `NowPlayingInfo`, `ChannelSwitcherModel` och `SearchModel` definieras i sin egen task och används inte före det. `kids:`-flaggan matchar `DiscoveryService.search`.
- **Review Focus:** varje rad har ett test i sin task (barnfilter, smal bredd/metrics, orientering, ägarskydd i Now Playing, avbrott, förhandsvisningspolicy, etiketter).
- **Proportion:** åtta uppgifter, signaturer och testnamn men inga kroppar.
