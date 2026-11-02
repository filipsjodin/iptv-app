# tvOS: Filmer och Serier som en sida med kategorirader och sidomeny

Datum: 2026-11-01. Gäller bara tvOS (`#if os(tvOS)`). Byggs på grenen `feat/tvos-catalog-browse` från `origin/main` (014ba7a, efter PR #10).

## Syfte

Idag är flikarna Filmer och Serier (`CatalogTab` i `Apps/Shared/LibraryBrowserView.swift`) en lista med kategorinamn. En
kategori öppnar en egen sida (`ItemListView`). Det är segt att bläddra: man måste backa ut och in för varje kategori.

Hem (`TVHomeView`) fungerar som ett riktigt bläddringsgränssnitt: alla rader ligger efter varandra på en lodrät sida
och man rullar nedåt. Filmer och Serier ska fungera likadant och se likadana ut. Eftersom en leverantör ofta har
hundratals kategorier behövs dessutom ett snabbt sätt att hoppa till en viss kategori: en sidomeny.

## Mål

- Filmer och Serier blir en lodrät sida med en rad per kategori, i leverantörens ordning.
- Utseende och fokusbeteende är samma som i Hem (se "Samma som Hem").
- Ett sidofönster till vänster listar alla kategorier. Att välja en rullar sidan till den kategorins rad.
- Sidan är snabb och tung nog för hundratals kategorier: rader och deras titlar laddas i takt med att man rullar.

## Inte mål

- **Ingen helskärmshero** (ingen rekommenderad titel, ingen Spela/Mer info-knapp, ingen "Scrolla ner"-text, ingen
  rotation av rekommenderad titel). Sidan är hela tiden i det som Hem kallar bläddringsläget.
- **Ingen sökning i den här ändringen.** Sökning blir en egen flik (kanaler, filmer och serier samtidigt) i en senare
  ändring. Sökfältet tas bort från Filmer och Serier på tvOS (se "Mina val").
- iOS rörs inte. `CatalogTab` och `ItemListView` fungerar som idag där.
- Ingen ny datamodell eller ny synkronisering. Samma bibliotek, samma kategorier.

## Samma som Hem

Svar på frågan "är backdrop, omslag osv. precis detsamma som på Hem": ja. Det som återanvänds oförändrat:

- Bakgrunden: titelns backdrop i helskärm för den fokuserade titeln (`HeroBackdrop`, lagret `HeroBackdropLayer`), med
  förhandsvisning (`PreviewController`, som själv väntar ut 1,5 s efter fokus).
- Uppgifterna om den fokuserade titeln överst (`HeroInfoPanel` via `BrowseInfoLayer`, utan knappar).
- Radytan i nedre delen (`rowsFraction` 0,58), övertoningen längst upp i den, rubriken, 80 pt sidomarginal, kortens
  mått (`PosterCard`, `.buttonStyle(.card)`, `TitleShelf.focusPadding`) och avstånd.
- Fokus på ett kort: `HeroModel.focus`, `PreviewController.focusChanged` och `HeroModel.prefetchWindow`.
- Ett kort öppnar titelns detaljsida (`TitleDestination`) och skickar med förhandsvisningen, som sidan tar över.
  Förhandsvisningen stoppas när fliken lämnas eller spelaren öppnas (`shutDown`, `homeTabActive`).
- "Fortsätt titta" överst: bara filmer i Filmer och bara avsnitt i Serier, som idag (`ContinueWatchingCard`, spelar
  direkt).

Skillnaden mot Hem är alltså bara att helskärmsherons hela övre skärm saknas. Utan den finns inget "ingen titel
fokuserad"-läge: sidan öppnas med fokus på första kortet (se "Fokus"), och backdrop och info visar den titeln.

TVHomeView har idag allt detta som privata delar, inlagda i `body`. På grenen `perf/tvos-home` (inte mergad, parallellt
arbete) är samma fil omskriven (`HeroBackdropLayer`, `BrowseInfoLayer`). **Den här ändringen rör därför inte
`TVHomeView.swift`**, för att undvika sammanslagningskonflikter. Den nya sidan är en egen fil som använder de
öppna byggstenarna (`HeroBackdrop`, `HeroInfoPanel`, `HeroModel`, `PreviewController`, `PosterCard`,
`ContinueWatchingCard`) och upprepar den lilla layout- och fokuslogik som behövs. Att slå ihop de två vyerna till delad
kod är en uppföljning när perf-grenen är mergad. Namnen `rowsFraction` 0,58, övertoningen och `BrowseInfoLayer` i den här
texten avser Hem som det ser ut på `main` (värdena läses ur `TVHomeView.swift`).

## Sidan

- Överst "Fortsätt titta" (om det finns något), sedan en rad per kategori med kategorins namn som rubrik.
- Kategorierna kommer från `AppModel.catalogListing(playlistID:kind:)`. Kategorirader hämtas med
  `LibraryStore.items(playlistID:kind:categoryID:limit:offset:)` utanför huvudaktören (`offMain`), som idag.
- **Lata rader:** en rads titlar laddas först när raden närmar sig bild. Varje rad visar högst de första 20 titlarna
  (mitt val, justerbart). Raderna byggs lata (`LazyVStack`), som Hem.
- **"Visa alla"-kort:** sist i en rad som har fler titlar än de som visas ligger ett kort "Visa alla" som öppnar den
  befintliga `ItemListView` för kategorin (sidvis laddning, som idag). Det är enda vägen till titlar utöver de första,
  eftersom den gamla kategorisidan inte längre nås från listan.
- "Alla"-posten (`categoryID: nil`) från den gamla listan försvinner. Den finns inte i menyn och inte som rad.
- Tomma kategorier: en kategori utan titlar ska inte lämna en tom rubrik. Om det går att veta billigt före laddning
  ska menyn inte lista den; annars döljs raden när den visat sig vara tom. Byggaren väljer.
- Misslyckad läsning av biblioteket visar "The library could not be read." och tom lista visar "Nothing here yet.",
  som idag.
- **Barnprofiler:** `catalogListing` ger då åldersfiltrerade rader (`.kids(rows)`) i stället för leverantörens
  kategorier. Samma sida byggs av de raderna, och sidomenyn listar dem. Inget "Visa alla" där (raderna är redan
  filtrerade och har ingen kategori att öppna).

## Sidomenyn

**Öppna.** Tryck vänster medan fokus ligger på första kortet i en rad (alla rader, även "Fortsätt titta"). Menyn
glider in från vänster kant över sidan.

**Innehåll.** En lodrät lista med alla kategorier (eller barnprofilens rader), i samma ordning som på sidan. Posten som
motsvarar raden som hade fokus när menyn öppnades har fokus när menyn visas.

**Välja.** Att välja en kategori rullar sidan så att den kategorins rad hamnar i radytan (på samma plats som när man
bläddrar ner till en rad). **Fokus stannar i menyn, och menyn stängs inte.** Då kan man fortsätta bläddra bland
kategorierna och se sidan följa med. Rullningen ska också starta laddningen av den radens titlar.

**Stänga.** Menyn stängs av antingen Tillbaka eller höger (tryck åt höger på fjärrkontrollen). Tillbaka stänger bara
menyn och lämnar inte fliken. När menyn är stängd beter sig Tillbaka som idag.

**Fokus efter stängning.** Fokus går till det första kortet i raden som sidan senast rullades till (eller, om
ingen kategori valts, till kortet som hade fokus när menyn öppnades). Efter det är det vanligt bläddrande.
Backdrop och info följer det kortet.

**Bakgrund medan menyn är öppen.** Sidan syns bakom menyn (halvt genomskinlig eller suddad panel; byggaren väljer
något som matchar Hems visuella språk). Förhandsvisningen av en titel ska inte spela medan fokus ligger i menyn.

**Tillgänglighet.** Menyposterna är vanliga fokuserbara knappar med kategorinamnet som etikett.

## Integration

- `LibraryBrowserView` ersätter `CatalogTab` på tvOS med den nya sidan för flikarna Filmer och Serier. `HomeView`
  och iOS-grenen ändras inte.
- Sidan får `playlistID`, `kind` och `reloadKey` som idag, och läser om när en ny import blivit klar eller när vyn
  visas igen (för "Fortsätt titta" och Min lista), på samma sätt som Hem och `CatalogTab`.
- Flikbyte och spelare ska stoppa förhandsvisningen precis som i Hem. Därför behöver sidan veta om dess flik är
  vald (som `homeTabActive` för Hem).

## Mina val (kontrollera dessa)

1. **Sökfältet tas bort på tvOS** från Filmer och Serier, eftersom `.searchable` inte går ihop med den nya sidan och
   sökning ska bli en egen flik. Under tiden finns ingen sökning på tvOS. Ändra detta om du vill behålla fältet tills
   den nya fliken finns.
2. **Fokus stannar i menyn efter val** (min tolkning av "jag vill inte att fokus ändras till första kortet, ifall man
   vill bläddra vidare"). Fokus går till första kortet i den valda raden först när menyn stängs.
3. **20 titlar per rad** och "Visa alla"-kortet som utväg till resten.
4. **Menyn öppnas med fokus på posten för den rad man kom ifrån.**
5. "Alla"-posten och den gamla kategorisidans ingång från listan försvinner.

## Prestanda

Hem är nyligen optimerat för snabb bläddring (se `perf(tvos)`-commits och signposten `home.firstRows`). Den nya sidan
ska inte bli sämre: läs `HeroModel.current` bara i små egna vyer (som `HeroBackdropLayer` och `BrowseInfoLayer`),
inte i sidans `body`, och ladda inte alla kategorier på en gång. Mät med samma signpost-metod som Hem om det går.

## Test

Logik som inte är vy (vilka kategorier som listas, vilken rad menyn öppnas på, fönstret av titlar per rad, vad
"Visa alla" visas för) läggs i en testbar modell och testas i `Apps/SharedTests` i samma stil som
`DiscoveryUITests` och `HeroTests`. Testmålet körs bara på iOS-simulatorn (`IPTV-iOSTests`), så modellen får inte ligga
inom `#if os(tvOS)`. Bara vyerna är tvOS-specifika. Windows kan inte bygga Apple-koden: bygge och tester verifieras i
CI (jobbet `apple`) och av ägaren på Mac. Fokus- och rullningsbeteendet kan bara verifieras på simulatorn eller en
Apple TV; byggaren ska köra appen och prova flödet (öppna menyn, välja, bläddra, stänga med Tillbaka och höger, öppna
en titel och backa) innan det anses klart.

## Överlåtet åt byggaren

Uppdelningen av delad kod mellan Hem och den nya sidan; menyns exakta utseende och animation; hur tomma kategorier
hanteras; hur rullningen till en rad görs tekniskt; namn på nya typer och filer.
