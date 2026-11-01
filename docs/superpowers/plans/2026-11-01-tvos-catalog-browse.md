# tvOS: Filmer och Serier som kategorisida med sidomeny — Implementationsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** På tvOS ersätta Filmer- och Serier-flikarnas kategorilista med en Hem-lik sida (en rad per kategori, lata rader) och en sidomeny som hoppar mellan kategorierna.

**Architecture:** Ren, plattformsoberoende logik (`CatalogBrowseModel`, `CatalogMenuState`) i `Apps/Shared/Catalog/` som testas på iOS-simulatorn. En ny tvOS-vy (`TVCatalogView`) återanvänder Hems öppna byggstenar utan att röra `TVHomeView.swift`. Menyn är en egen vy ovanpå sidan. iOS är oförändrat.

**Tech Stack:** Swift 6, SwiftUI (tvOS 27), Swift Testing, XcodeGen (`Apps/project.yml` tar in nya filer automatiskt via kataloger).

**Spec:** `docs/superpowers/specs/2026-11-01-tvos-catalog-browse-design.md`

**Miljö (läs först):** Windows kan inte bygga Apple-koden. Skriv koden noggrant, kör inget bygge lokalt för `Apps/`. Verifiering sker i CI (jobbet `apple` i `.github/workflows/ci.yml`: bygger tvOS och kör `IPTV-iOSTests`) efter push, och av ägaren på Mac/Apple TV. Pusha inte och skapa ingen PR utan att ägaren ber om det; säg att koden är klar för CI.

## Global Constraints

- Gren: `feat/tvos-catalog-browse` från `origin/main` (014ba7a). Rör inte `Apps/Shared/Hero/TVHomeView.swift` (parallellt arbete på `perf/tvos-home`).
- Bara tvOS ändras. Allt som är vyer eller tvOS-specifikt ligger inom `#if os(tvOS)`. Modellfilerna (`CatalogBrowseModel`, `CatalogMenuState`) ligger **utanför** `#if os(tvOS)` så att iOS-testmålet kompilerar dem.
- Ingen helskärmshero. Inget sökfält på tvOS-sidan. Ingen "Alla"-post.
- Rader: högst `20` titlar visas per kategori; ett "Visa alla"-kort sist om kategorin har fler.
- Menyn öppnas med vänster från första kortet i en rad; väljer man en kategori stängs den **inte** och fokus stannar i menyn; Tillbaka eller höger stänger. Efter stängning går fokus till första kortet i den senast valda raden.
- Visuellt som Hem på main: radytan `height * 0.58`, 80 pt sidomarginal, `PosterCard` med `.buttonStyle(.card)`, `TitleShelf.focusPadding`, kortavstånd 24, radavstånd 24. Ingen lägre bildkvalitet (ägarens krav).
- tvOS ger inte fokus åt vyer med alfa 0: osynliga men fokuserbara vyer använder opacity `0.01`.
- Kommentarer och användartexter i samma stil som koden omkring: svenska kommentarer, engelska UI-strängar (`"Show All"`).
- Barnprofiler (`catalogListing` ger `.kids`) visar sina färdiga rader utan "Visa alla".
- Commit-meddelanden på svenska i formen `feat(tvos): ...`, avslutade med `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus

- Kategori utan titlar: raden döljs och försvinner ur menyn; ingen tom rubrik och ingen meny-post som leder ingenstans.
- Spellista med 0 kategorier (eller bibliotek ej läst): "Nothing here yet." / "The library could not be read." som idag, ingen krasch, ingen meny.
- Snabbt hopp i menyn över många lata rader: samma rad får inte laddas två gånger samtidigt; en avbruten laddning får inte lämna raden "laddar" för alltid.
- Ny import (`reloadKey`) medan sidan visas: sektioner och laddade rader byggs om från början, och en gammal sidas svar skriver inte över nya.
- Barnprofil: menyn listar barnradernas rubriker; "Visa alla" visas aldrig.

---

### Task 1: `CatalogBrowseModel` — sektioner, lata rader, menyposter

**Files:**
- Create: `Apps/Shared/Catalog/CatalogBrowseModel.swift`
- Test: `Apps/SharedTests/CatalogBrowseModelTests.swift`

**Interfaces:**
- Consumes: `CatalogListing` (`.categories([Core.Category])`, `.kids([HomeRow])`) från `AppModel+Discovery.swift`; `Library.LibraryItem`; `ContentKind`.
- Produces (alla internal, ingen `#if`):
  - `struct CatalogSection: Identifiable, Equatable` med `let id: String` (`"cat:<providerID>"` eller `"kids:<index>"`), `let title: String`, `let categoryID: String?` (nil för barnrader), `var phase: Phase`, där `enum Phase: Equatable { case unloaded, loading, loaded(items: [Library.LibraryItem], hasMore: Bool) }`.
  - `struct CatalogMenuEntry: Identifiable, Equatable { let id: String; let title: String }` (id = sektionens id).
  - `@MainActor @Observable final class CatalogBrowseModel` med:
    - `static let rowLimit = 20`
    - `typealias Loader = @Sendable (_ categoryID: String, _ limit: Int) async throws -> [Library.LibraryItem]`
    - `private(set) var sections: [CatalogSection]`
    - `var menuEntries: [CatalogMenuEntry] { get }` — alla sektioner utom de som är `.loaded` med noll titlar.
    - `func configure(_ listing: CatalogListing)` — bygger om `sections` helt (kategorier: `phase = .unloaded`; barnrader: `phase = .loaded(items: titles, hasMore: false)`, rader utan titlar utelämnas) och nollställer pågående laddningar.
    - `func load(sectionID: String, using loader: Loader) async` — gör inget om sektionen inte är `.unloaded`, är en barnrad eller saknas; sätter `.loading`; anropar `loader(categoryID, Self.rowLimit + 1)`; sätter `.loaded(items: prefix(rowLimit), hasMore: count > rowLimit)`; vid fel eller `CancellationError` återställs till `.unloaded`. Ett svar som kommer efter att `configure` kört om (ny generation) kastas.
    - `func section(id: String) -> CatalogSection?`
    - `func firstItemID(inSection id: String) -> String?` — första titelns `LibraryItem.id`, nil om raden inte är laddad.

- [ ] **Step 1: Write the failing tests** i `CatalogBrowseModelTests` (`@MainActor struct`, Swift Testing, samma stil som `HeroTests`). Hjälpare `item(_ id: String) -> Library.LibraryItem` (kind `.movie`) och `categories(_ names: String...) -> CatalogListing`. Tester, med exakta förväntningar:
  - `categoriesBecomeUnloadedSectionsInOrder`: `configure(.categories([A,B,C]))` ger `sections.map(\.title) == ["A","B","C"]`, alla `.unloaded`, `categoryID` satt, `menuEntries.count == 3`.
  - `loadStoresAtMostRowLimitAndFlagsMore`: loader returnerar 21 titlar → `.loaded(items.count == 20, hasMore: true)`; loader returnerar 20 → `hasMore == false`; loader anropas med `limit == 21`.
  - `emptyCategoryIsHiddenFromMenu`: loader returnerar `[]` → `menuEntries` saknar sektionen, men `sections` behåller den.
  - `sameSectionIsNotLoadedTwice`: två samtidiga `load` för samma id (loader räknar anrop, väntar på en continuation) ger ett loader-anrop.
  - `failedOrCancelledLoadResetsToUnloaded`: loader kastar → `.unloaded`; därefter lyckas ett nytt `load`.
  - `staleResponseAfterReconfigureIsDropped`: starta `load` med väntande loader, kör `configure` på nytt, släpp loadern → den nya sektionen är fortfarande `.unloaded`.
  - `kidsRowsAreLoadedAndNeverHaveMore`: `configure(.kids([row med 30 titlar, tom rad]))` → en sektion, `.loaded(items.count == 30, hasMore: false)`, `categoryID == nil`; `load` på den gör inget.
  - `firstItemIDRequiresLoadedSection`: nil före laddning, första titelns id efter.

- [ ] **Step 2: Run to verify fail** — kan inte köras lokalt (Apple-mål). Kontrollera att filen kompilerar mentalt mot signaturerna ovan; felet verifieras i CI vid Task 7. Hoppa över körning här och notera det i commit-texten.

- [ ] **Step 3: Implement `CatalogBrowseModel`** enligt Interfaces i `Apps/Shared/Catalog/CatalogBrowseModel.swift`. Generationsräknare (`private var generation = 0`, ökas i `configure`) jämförs efter `await`.

- [ ] **Step 4: Verify** — granska koden mot varje testförväntan ovan (ingen körning möjlig lokalt).

- [ ] **Step 5: Commit**

```bash
git add Apps/Shared/Catalog/CatalogBrowseModel.swift Apps/SharedTests/CatalogBrowseModelTests.swift
git commit -m "feat(tvos): modell för kategorisidan (sektioner, lata rader, menyposter)"
```

---

### Task 2: `CatalogMenuState` — menyns tillstånd

**Files:**
- Create: `Apps/Shared/Catalog/CatalogMenuState.swift`
- Test: `Apps/SharedTests/CatalogMenuStateTests.swift`

**Interfaces:**
- Consumes: `CatalogMenuEntry` (Task 1).
- Produces (ingen `#if`): `struct CatalogMenuState: Equatable` med
  - `private(set) var isOpen = false`
  - `private(set) var focusedEntryID: String?` — posten som har fokus i menyn.
  - `private(set) var selectedSectionID: String?` — senast valda rad (rullningsmål).
  - `mutating func open(from sectionID: String?, entries: [CatalogMenuEntry])` — öppnar; fokus på `sectionID` om den finns i `entries`, annars första posten; tom `entries` öppnar inte.
  - `mutating func select(_ entryID: String)` — sätter `selectedSectionID = entryID` och `focusedEntryID = entryID`; **stänger inte**.
  - `mutating func close() -> String?` — stänger och returnerar sektionen fokus ska till (`selectedSectionID`, annars `sectionID` som menyn öppnades från), nollställer `selectedSectionID`.

- [ ] **Step 1: Write failing tests** (`CatalogMenuStateTests`): `opensOnOriginSection`, `fallsBackToFirstEntryWhenOriginMissing`, `emptyEntriesDoNotOpen`, `selectKeepsMenuOpenAndFocusInMenu` (efter `select("b")`: `isOpen == true`, `focusedEntryID == "b"`, `selectedSectionID == "b"`), `closeReturnsLastSelected` (select a, select c, close → `"c"`, `isOpen == false`), `closeWithoutSelectionReturnsOrigin`, `closeResetsSelection` (andra `close()` efter ny `open` utan val returnerar origin).
- [ ] **Step 2: Run** — se Task 1 Step 2 (verifieras i CI).
- [ ] **Step 3: Implement `CatalogMenuState`** enligt Interfaces.
- [ ] **Step 4: Verify** mot testförväntningarna.
- [ ] **Step 5: Commit** `feat(tvos): menytillstånd för kategorisidan`.

---

### Task 3: `AppModel.catalogItems` — hämta en kategoris första titlar

**Files:**
- Modify: `Apps/Shared/AppModel+Discovery.swift` (efter `catalogListing`, ca rad 41)
- Test: `Apps/SharedTests/DiscoveryUITests.swift` (lägg ett test i befintlig `struct`, använd `discoveryModel()`)

**Interfaces:**
- Consumes: `LibraryStore.items(playlistID:kind:categoryID:limit:offset:)` (`Packages/IPTVPlatform/Sources/Library/LibraryStore.swift:368`), `offMain`.
- Produces: `func catalogItems(playlistID: UUID, kind: ContentKind, categoryID: String, limit: Int) async throws -> [LibraryItem]` på `AppModel` (offset 0, utanför huvudaktören). Passar som `CatalogBrowseModel.Loader` (Task 1) via en closure som fångar `playlistID`/`kind`.

- [ ] **Step 1: Write failing test** `catalogItemsReturnsCategoryTitlesUpToLimit` i `DiscoveryUITests`: med `discoveryModel()`, `catalogItems(..., kind: .movie, categoryID: "10", limit: 2)` ger 2 titlar vars `providerID` ingår i `["101","102","106"]` (kategori 10 i fixturen har 101, 102, 106); med `limit: 10` ger exakt de tre; `categoryID: "11"` ger `["103","105"]` som mängd; okänt id `"999"` ger `[]`.
- [ ] **Step 2: Run** — verifieras i CI.
- [ ] **Step 3: Implement** `catalogItems` (kapa med `store.items(... limit:, offset: 0)`).
- [ ] **Step 4: Verify** mot testet.
- [ ] **Step 5: Commit** `feat(tvos): AppModel.catalogItems för kategorirader`.

---

### Task 4: `TVCatalogView` — sidan utan meny

**Files:**
- Create: `Apps/Shared/Catalog/TVCatalogView.swift` (hela filen inom `#if os(tvOS)`)
- Modify: `Apps/Shared/LibraryBrowserView.swift` — `ItemListView` från `private` till internal (behövs i Task 5); tvOS-flikarna Movies/Series (rad 61–66) använder `TVCatalogView` i stället för `CatalogTab`.

**Interfaces:**
- Consumes: `CatalogBrowseModel`, `AppModel.catalogListing`, `AppModel.catalogItems` (Task 3), `AppModel.continueWatching(playlistID:kind:)`, `HeroModel`, `HeroBackdrop(hero:preview:)`, `HeroInfoPanel(hero:)`, `PreviewController` (`model.makePreviewController()`, `focusChanged(to:playlistID:)`, `stopNow()`), `PosterCard`, `ContinueWatchingCard`, `TitleDestination`, `playerCover`, `PlayerPresentation`, `Environment(\.homeTabActive)`-mönstret.
- Produces: `struct TVCatalogView: View { init(playlistID: UUID, kind: ContentKind, reloadKey: Date?, tabActive: Bool) }`. Tillståndet `focused: CardID?` där `CardID { sectionID: String; itemID: String }` är vyns egen fokusnyckel (menyn i Task 5 behöver den).

Sidans uppbyggnad är Hem på main (`Apps/Shared/Hero/TVHomeView.swift`), men utan helskärmsheron: `ZStack { Color.black; HeroBackdrop }`, infopanelen i övre delen (`HeroInfoPanel` visas när `heroModel.current != nil`), radytan i nedre `0,58` av höjden som en lodrät `ScrollView` med `LazyVStack(spacing: 24)`, kopiera fokushanteringen (`handleFocus`, `locate`, `refocus`, `shutDown`, `onAppear`/`onDisappear`/`onChange(of: tabActive)`/`presented`-hanteringen, `playerCover`, `navigationDestination` till `TitleDestination` med `previewController`). Fokus ligger alltid på ett kort (inget "ingen fokus"-läge): `defaultFocus` på första kortet (första sektionen med innehåll).

- [ ] **Step 1: Implement the page** i `TVCatalogView.swift`:
  - `.task(id: LoadKey(reloadKey, generation))` laddar `catalogListing` → `model.configure(listing)`; fel sätter `failed`; tomt resultat visar "Nothing here yet.", fel "The library could not be read." (samma texter som `CatalogTab`).
  - "Fortsätt titta"-rad överst om `model.continueWatching(playlistID:kind:)` ger något (läses om vid `generation`-ökning: `onAppear` och spelare stängd), spelar direkt som i `TVHomeView.playContinue`.
  - Varje `CatalogSection` visas som rubrik + horisontell `LazyHStack` av `PosterCard`-knappar (`detail = DetailTarget`), sektionens `.task(id: reloadKey)` anropar `catalogModel.load(sectionID:using:)` när raden kommer i bild; tills den är laddad visas en tom platshållare med samma höjd som en kortrad (`PosterCard.defaultWidth * 1.5` plus rubrik) så att rullning inte hoppar; en rad som blir tom döljs (`menuEntries`-logiken).
  - Sist i en rad med `hasMore` ligger ett kort "Show All" (`Label("Show All", systemImage: "chevron.right.circle")`, samma kortstorlek, `.buttonStyle(.card)`) som `NavigationLink` till `ItemListView(playlistID:kind:categoryID:title:reloadKey:)`.
  - Fokus på "Show All"-kortet nollställer hero/förhandsvisning (`heroModel.focus(nil, ...)`, `previewController?.focusChanged(to: nil, ...)`).
  - Hero läses i en egen liten vy (`private struct CatalogBackdropLayer` och motsvarande info-lager), inte i `body` (prestanda; se spec).
  - Förhandsvisning stoppas via `shutDown()` precis som i Hem.
- [ ] **Step 2: Wire into `LibraryBrowserView`**: på tvOS `TVCatalogView(playlistID:kind:reloadKey:tabActive: selectedTab == .movies/.series)`; iOS behåller `CatalogTab`. Gör `ItemListView` internal.
- [ ] **Step 3: Verify** — kompilerar bara på Apple; läs igenom att varje `@FocusState`/`@State` används, att inget i `body` läser `heroModel.current`, och att iOS-grenen inte ändrats. Verifieras i CI vid Task 7.
- [ ] **Step 4: Commit** `feat(tvos): Filmer och Serier som en sida med kategorirader`.

---

### Task 5: Sidomenyn

**Files:**
- Create: `Apps/Shared/Catalog/CatalogCategoryMenu.swift` (`#if os(tvOS)`)
- Modify: `Apps/Shared/Catalog/TVCatalogView.swift`

**Interfaces:**
- Consumes: `CatalogMenuState`, `CatalogMenuEntry` (Task 1–2); `TVCatalogView.focused`/`CardID` (Task 4).
- Produces: `struct CatalogCategoryMenu: View { let entries: [CatalogMenuEntry]; @FocusState.Binding var focusedEntry: String?; let onSelect: (String) -> Void }` — en lodrät lista av knappar (rullbar), vänsterkant, bredd ca `480`, halvgenomskinlig bakgrund (`.regularMaterial`), `.focusSection()`.

- [ ] **Step 1: Open on left.** På varje korts knapp i `TVCatalogView` som är *första kortet i sin rad* (inklusive Fortsätt titta): `.onMoveCommand { direction in if direction == .left { openMenu(from: sectionID) } }`. `openMenu` anropar `menuState.open(from:entries:)` och sätter menyns fokus. Om menyn inte kan öppnas (tom `entries`) händer inget.
- [ ] **Step 2: Select = scroll, menu stays.** `onSelect(id)`: `menuState.select(id)`, `withAnimation { proxy.scrollTo(id, anchor: .top) }` med radytans `ScrollViewReader` (sektionernas vyer har `.id(section.id)`), samt `catalogModel.load(sectionID:...)` för raden. Fokus stannar på menyposten.
- [ ] **Step 3: Close.** `.onExitCommand` (Tillbaka) när menyn är öppen: stäng, annars normalt beteende (ingen `onExitCommand` när stängd). `.onMoveCommand` höger i menyn: stäng. `close()` returnerar sektionsid; sätt `focused = CardID(sectionID:, itemID: catalogModel.firstItemID(inSection:))` om raden är laddad, annars vänta tills den laddats (en `.onChange` av sektionens fas sätter fokus) och tillåt inte att fokus fastnar i menyn.
- [ ] **Step 4: Preview.** Medan menyn är öppen ska ingen förhandsvisning spela: `previewController?.focusChanged(to: nil, ...)` när menyn öppnas; vid stängning sköter kortfokus resten.
- [ ] **Step 5: Verify** — granska flödet: öppna → välj A → välj B (menyn kvar) → höger (stänger, fokus på B:s första kort) → bläddra; öppna → Tillbaka stänger utan att lämna fliken; Tillbaka med stängd meny lämnar som idag.
- [ ] **Step 6: Commit** `feat(tvos): sidomeny för kategorier på Filmer och Serier`.

**Risk (tvOS-fokus, kan inte provas lokalt):** om `onMoveCommand` inte utlöses från det första kortet när fokus inte kan flytta sig vänster, använd reserven: en osynlig fokuserbar vy (opacity `0.01`, bredd 1) först i varje rads `LazyHStack`; när den får fokus öppnas menyn. Bygg bara reserven om ägaren rapporterar att vänster inte öppnar menyn.

---

### Task 6: Testlista och dokumentation

**Files:**
- Modify: `README.md` (avsnittet "Testlista …" — följ strukturen i de befintliga; lägg till "Testlista Filmer/Serier (tvOS)")

- [ ] **Step 1:** Lägg till en punktlista som ägaren kör på Mac/Apple TV: vänster från första kortet öppnar menyn (även på Fortsätt titta); välja en kategori rullar dit och menyn stannar; Tillbaka och höger stänger; fokus efter stängning på radens första kort; "Show All" öppnar hela kategorin; tomma kategorier syns inte i menyn; barnprofil visar sina rader och ingen "Show All"; snabb bläddring/hopp i menyn utan hack; backdrop/info/förhandsvisning som på Hem; ingen sökning på tvOS tills söktabben finns (känd begränsning).
- [ ] **Step 2: Commit** `docs: testlista för Filmer och Serier på tvOS`.

---

### Task 7: Helhetsgranskning och CI

- [ ] **Step 1:** Kör `git diff origin/main --stat`: bara filer enligt planen, `TVHomeView.swift` oförändrad, ingen ändring i iOS-grenar.
- [ ] **Step 2:** Granska `git diff origin/main` mot specen och Review Focus. Rätta fel.
- [ ] **Step 3:** Rapportera till ägaren: allt är skrivet men oprövat (ingen Apple-toolchain lokalt). Fråga om grenen ska pushas och en draft-PR öppnas så att CI (`apple`-jobbet) bygger tvOS och kör testerna. Pusha inte utan svar.
