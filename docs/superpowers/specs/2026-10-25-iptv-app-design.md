# IPTV-app för Apple TV, iPhone och iPad – designdokument

**Datum:** 2026-10-25
**Status:** Utkast för granskning
**Arbetsnamn:** "IPTV-appen" (riktigt namn bestäms senare)

Markeringar i dokumentet:
- **[Beslutat]**: ägaren har bestämt det i samtalet.
- **[Mitt beslut]**: designerns förslag. Ägaren kan ändra det, och byggaren får justera om det finns goda skäl.
- **[Byggarens val]**: lämnas uttryckligen åt den som bygger.

---

## 1. Avsikt och varför

Ägaren tittar på IPTV via en Xtream Codes- eller M3U-leverantör, främst på Apple TV från soffan. Befintliga IPTV-appar fungerar tekniskt men **känns billiga**: de är fula, animationerna är ryckiga eller löjliga, och det är **svårt att hitta något att titta på**. Den största saknaden är Netflix-känslan: man stannar på en titel och en trailer börjar spela, vilket väcker lust att titta.

Appen ska kännas som en förstklassig streamingtjänst (Netflix eller Apple TV-appen) och vara så native som möjligt. Den ska ge bästa möjliga bild och ljud: HDR, Dolby Vision, Dolby Atmos och surround.

Appen är till för personligt bruk nu men ska byggas produktionsklar, så att den kan läggas ut på App Store senare.

**Framgång betyder** att ägaren hellre öppnar den här appen än något annat på Apple TV:n. Det ska gå lätt att hitta något att se, att upptäcka nytt ska vara roligt, och allt ska kännas smidigt.

## 2. Mål, icke-mål och anti-mål

### Mål
1. Lägga till en eller flera spellistor (Xtream Codes eller M3U-URL).
2. Kategorierna Filmer, Serier, Live TV och TV-tablå (EPG).
3. Automatisk metadata: betyg, skådespelare, beskrivningar, högupplöst artwork, säsonger och avsnitt.
4. Netflix-lik upptäckt: bakgrund och förhandsvisning (§6.5) som följer fokus, "För dig", "Topp 10 i Sverige", genrerader, "Liknande titlar", 👍/👎 och Min lista.
5. Bästa möjliga uppspelning med byte av ljudspår och undertexter, nedladdning av undertexter från OpenSubtitles och val av spelare.
6. Profiler per spellista med egen historik, egna rekommendationer och egna inställningar.
7. iPhone och iPad: offline-nedladdning för resor.
8. Smidig prestanda (se §9).

### Icke-mål (inte i första versionen) [Mitt beslut]
- Inspelning (DVR), timeshift och catch-up (tv_archive). Datamodellen ska däremot inte stänga dörren för dem.
- Flera strömmar samtidigt (multiview).
- macOS, visionOS och Android.
- Chromecast. AirPlay räcker.
- Sport (sportsida, matcher mot kanaler, följda lag och ligor). Ägaren valde bort det 2026-10-31. Live TV och EPG täcker behovet.
- Eget innehåll eller egen innehållsserver. Appen spelar bara upp det användaren själv har tillgång till.

### Anti-mål (misslyckande även om allt fungerar tekniskt) [Beslutat]
- **Dålig prestanda**: hack, ryckig scroll, ryckiga fokusbyten eller tomma rutor som "poppar in".
- **Billiga eller löjliga animationer.** Allt ska kännas som Apples egna appar eller Netflix.
- Svårt att hitta något att titta på.

## 3. Begränsningar och förutsättningar

- **Plattformar:** tvOS, iOS och iPadOS. **Lägsta version är 27** [Beslutat]. Apple TV är huvudplattformen.
- **Utvecklingsmiljö:** Koden skrivs på Windows. Ägaren har tillgång till en Mac när appen ska testas på riktiga enheter [Beslutat]. Därför:
  - Xcode-projektet **genereras** från en textfil (XcodeGen `project.yml` eller Tuist) och checkas inte in som `.pbxproj` [Mitt beslut]. Det går inte att redigera `.pbxproj` för hand på ett pålitligt sätt.
  - **GitHub Actions på macOS-runners** bygger iOS- och tvOS-målen och kör alla tester vid varje push. Det är den primära verifieringen [Beslutat: GitHub].
- **Distribution:**
  - Nu: sideload via Xcode med gratis Apple-ID. Appen upphör att fungera efter 7 dagar, och tvOS kräver att Apple TV:n paras ihop med Xcode.
  - Senare: Apple Developer-konto (99 USD/år), och CI laddar upp till TestFlight via App Store Connect API. Ägaren kan tänka sig att skaffa kontot. CI-flödet ska byggas så att TestFlight-steget kan slås på enbart genom att lägga till secrets.
- **iCloud/CloudKit** fungerar bara med betalt konto. Därför är synk ett senare steg, och allt ska fungera fullt ut lokalt utan det.
- **Publikt GitHub-repo** [Beslutat]. Därför gäller strikt att inget känsligt någonsin checkas in:
  - **Hemliga nycklar** (TMDB, OpenSubtitles API-nyckel, eventuellt OMDb) ligger i GitHub Secrets. CI skriver dem till en `.xcconfig`, och lokalt används en `Secrets.xcconfig` som står i `.gitignore`.
  - Spellist-URL:er, lösenord, serveradresser och oanonymiserad testdata får aldrig finnas i repot eller i CI-loggar.
  - [Mitt beslut:] Hemlighetsskanning (gitleaks) körs i CI och som pre-commit-hook, och GitHubs secret scanning och push protection är påslagna. `.gitignore` täcker `Secrets.xcconfig`, samt `*.m3u`, `*.m3u8` och `*.xml(.gz)` utanför `Fixtures/`.
  - Nycklar som byggs in i appen kan i teorin plockas ut ur en distribuerad app. Det är acceptabelt för gratisnycklar nu. Inför en App Store-release kan en liten proxy övervägas.
- **Endast gratisnivåer** av externa API:er [Beslutat]. Appen ska hantera rate limits med cache och backoff, och degradera snyggt.
- **Utvecklarkonto:** saknas ännu, och det är okänt när det skaffas [Beslutat]. Appen byggs för gratis sideload. TestFlight-jobbet förbereds men är avstängt tills ägaren säger till. Varje fas avslutas med en kort checklista för vad ägaren ska testa på riktig Apple TV vid Macen: prestanda, Dolby Vision/Atmos och fjärrkontrollen. De sakerna kan inte verifieras i CI.
- **Användarens inloggningsuppgifter** (Xtream-lösenord, OpenSubtitles-inloggning) lagras **i Keychain**, aldrig i databas eller UserDefaults.
- **Språk i gränssnittet:** svenska och engelska, som följer systemet [Mitt beslut].

## 4. Arkitektur (översikt) [Mitt beslut om inget annat anges]

- **Swift 6** med strict concurrency, **SwiftUI**, `@Observable` och Liquid Glass-design.
- **En kodbas med lokala Swift-paket**, där de plattformsspecifika vyerna ligger i respektive app-mål:

| Modul | Ansvar |
|---|---|
| `Core` | Domänmodeller, profiler, inställningar, Keychain |
| `Providers` | Xtream Codes API-klient, M3U-tolk, XMLTV-tolk, normalisering till domänmodeller |
| `Library` | Lokal databas (se nedan), import och uppdatering, sökning |
| `Metadata` | TMDB-klient, matchning av titlar, bild-URL:er, cache |
| `Discovery` | "För dig", topp 10, genrerader, liknande titlar |
| `Playback` | Gemensamt spelarprotokoll, AVPlayer-motor, VLC-motor, val av motor, undertextrendering |
| `Subtitles` | OpenSubtitles-klient, SRT/VTT-tolk, synkjustering |
| `Downloads` | Bakgrundsnedladdning (endast iOS/iPadOS) |
| `DesignSystem` | Färger, typografi, kort, fokusbeteende, animationer |
| `TVApp`, `iOSApp` | Plattformens navigation och vyer |

- **Lokal databas:** SQLite via **GRDB** med FTS5 för sökning. Valet ger förutsägbar prestanda vid 50 000–200 000 poster, vilket SwiftData inte gör.
- **Bilder:** Nuke (eller motsvarande) med nedskalning till rätt storlek, disk- och minnescache samt förhämtning.
- **Nätverk:** `URLSession` och async/await. Inga tunga beroenden utöver GRDB, Nuke och VLCKit [Byggarens val om det finns starka skäl].

## 5. Spellistor och inloggning

- **Lägga till spellista** [Beslutat]:
  - **Xtream Codes:** server-URL, användarnamn och lösenord.
  - **M3U:** URL, och eventuellt en separat XMLTV-URL för EPG.
  - Båda vanliga sätten ska stödjas fullt ut [Beslutat]. [Mitt beslut:] Dessutom M3U-fil från Filer på iOS, och inmatning via iPhone-tangentbordet (Continuity) på tvOS så att man slipper skriva med fjärrkontrollen.
- **Verklig testdata** [Beslutat]: ägaren delar sin spellista för granskning.
  - Den analyseras **endast lokalt** och checkas aldrig in.
  - Ett litet anonymiseringsverktyg (fas 1) gör om den till fixtures utan inloggningsuppgifter, serveradresser eller tokens.
  - Bara de avidentifierade fixturerna hamnar i repot.
- Användaren kan ha flera spellistor och byta mellan dem. Varje spellista har ett eget namn.
- **Xtream** använder `player_api.php`: `get_live_categories`/`get_live_streams`, `get_vod_categories`/`get_vod_streams`/`get_vod_info`, `get_series_categories`/`get_series`/`get_series_info` och `get_short_epg`. Fullständig EPG hämtas från `xmltv.php`.
  - `user_info.max_connections` och `exp_date` läses av och visas.
- **M3U:** tolka `#EXTINF` med `tvg-id`, `tvg-name`, `tvg-logo` och `group-title`. Typen (film, serie eller live) avgörs av URL-mönster (`/movie/`, `/series/`, `/live/`, filändelse) och därefter av heuristik på group-title. Serier grupperas via mönster som `S01E02` i namnet.
- **Import:** första importen körs i bakgrunden med förloppsindikator och sparas i databasen. Därefter visas allt från databasen direkt, och uppdatering sker tyst i bakgrunden: vid start om datan är äldre än X timmar, och manuellt.
- **Formatöversikt** i inställningarna: statistik över filformat och kodekar i spellistan (.mkv, .mp4, .m3u8, .ts med mera), så att man ser hur ofta reservspelaren behövs.
- **Live-strömmar** hämtas som `.m3u8` (HLS) när leverantören erbjuder det, annars `.ts`.

## 6. Upptäckt och gränssnitt

### 6.1 Navigation
- **tvOS:** flikrad överst i Liquid Glass med Sök, Hem, Filmer, Serier, Live TV och Min lista, samt inställningar via profilikonen.
- **iOS:** flikrad nederst med Hem, Filmer, Serier, Live TV, Sök och Nedladdningar.
- **iPadOS:** sidomeny med samma innehåll.
- **Profilväljaren** "Vem tittar?" visas vid start om spellistan har mer än en profil.

### 6.2 Startsidan på tvOS – "bakgrunden följer fokus" [Beslutat: alternativ A i mockupen]
- Den titel som har fokus fyller hela bakgrunden: backdrop, titellogga (TMDB-logo om sådan finns, annars text), betyg, år, längd, kvalitetsmärken (4K, Dolby Vision, HDR, Atmos, 5.1), kort beskrivning, samt knapparna Spela, Min lista och 👍.
- Efter cirka 1,5 sekunders stillastående fokus tonar artworken över i **förhandsvisningen** (se §6.5), först tyst. Ljudet tonar sedan in, och det ska gå att stänga av med en inställning. Förhandsvisningen stoppas direkt när fokus flyttas.
- Raderna ligger i nedre delen. Rutan med fokus lyfts med tvOS standardparallax och fokuseffekt.
- **Rader på Hem:** Fortsätt titta, För dig, Topp 10 filmer i Sverige, Topp 10 serier i Sverige, Nyligen tillagt, Min lista, genrerader (Action, Komedi, Skräck, Drama, Thriller, Sci-fi, Dokumentär, Barn med flera).
- Filmer och Serier har samma struktur men filtreras på typ. Där finns också leverantörens egna kategorier som rader eller en lista.

### 6.3 Detaljsidan [Beslutat: godkänd mockup]
- Förhandsvisningen fortsätter i bakgrunden.
- Översta delen innehåller titellogga, betyg (TMDB, samt IMDb och Rotten Tomatoes om OMDb används), år, genrer, åldersgräns, kvalitetsmärken, beskrivning, skådespelare i urval samt regissör eller skapare.
- **Knappar:** Spela, eller "Fortsätt S2:E4 · 32 min kvar". Dessutom Från början, Min lista, 👍 och 👎, samt nedladdning på iOS.
- **Serier:** säsongsflikar med avsnitten i en horisontell rad. Varje avsnitt har stillbild, titel, längd, beskrivning och en förloppslinje (röd). Sedda avsnitt markeras.
- Längre ner finns **Liknande titlar**, som bara visar titlar som finns i spellistan, och **Skådespelare och team**, där ett klick visar allt med personen som finns i spellistan.
- **Info-ruta:** ljudspår, undertexter (plus "Sök fler"), video (upplösning, HDR-format, kodek) och vilken spelare som används.

### 6.4 iPhone och iPad
- Vanlig iOS-struktur med samma innehåll. Detaljsidan har förhandsvisningen eller artwork överst, men förhandsvisningen startar inte automatiskt vid scroll.
- Spelaren har liggande helskärm, bild-i-bild och AirPlay.

### 6.5 Förhandsvisning i stället för trailer [Beslutat]
tvOS saknar WebKit, och nästan alla trailers (via TMDB) ligger på YouTube. Därför används **ingen YouTube** och inga trailers från tredje part.
- **Förhandsvisning ur den egna spellistan:** titelns egen ström startas **tyst** i AVPlayer en bit in, cirka 10 % av speltiden. Den exakta startpunkten är [Byggarens val], men förtexterna ska undvikas och slutet får inte avslöjas. För serier används S1E1. Ljudet tonas in om inställningen tillåter det.
- **Reserv: bara artwork** (backdrop, som Netflix gör när trailer saknas). Reserven används när:
  - strömmen inte kan spelas i AVPlayer, till exempel MKV (VLC används inte för förhandsvisningar [Mitt beslut])
  - förhandsvisningen inte har startat inom cirka 3 s
  - anslutningen behövs till annat (`max_connections`)
  - användaren har stängt av förhandsvisningar
- **Inställningar per profil:** förhandsvisningar på eller av, och ljud i förhandsvisningar på eller av.
- Förhandsvisningsströmmen stängs **omedelbart** när fokus flyttas, så att den aldrig tar en anslutning i onödan.

### 6.6 Metadata
- **TMDB** är huvudkällan. Använd `tmdb_id` från Xtream-`get_vod_info` när det finns. Annars görs en sökning på rensad titel och år: ta bort taggar som "4K", "MULTI", "SE:", "[Dolby]" och liknande, och tolka årtal ur namnet. En konfidenspoäng beräknas, och titlar under tröskeln visas med leverantörens egen data i stället för fel metadata.
- Allt hämtas när det behövs (lazy) och sparas i databasen, och bilderna cachas.
- **OMDb** (gratis nyckel, 1000 anrop per dag) används för IMDb- och Rotten Tomatoes-betyg. Det är valfritt och slås av om nyckel saknas [Mitt beslut].
- Svensk text (`language=sv-SE`) används om den finns, med engelska som reserv.

### 6.7 Rekommendationer
- **För dig** räknas ut **på enheten** per profil. Den bygger på tittarhistorik (andel sett), 👍/👎 och Min lista, viktat mot genrer, skådespelare, regissörer och nyckelord från TMDB, plus TMDB:s `recommendations`/`similar` för titlar man har sett eller gillat. Titlar som fått 👎 och liknande titlar nedprioriteras. Bara titlar som finns i spellistan visas.
- **Topp 10 i Sverige:** TMDB saknar riktiga nationella topp 10-listor. Använd TMDB `trending` och `popular` med `region=SE` och filtrera på det som finns i spellistan [Mitt beslut]. Listan kallas "Topp 10 i Sverige" men bygger på popularitet. Byggaren får byta till en bättre gratis källa om en sådan finns.
- **Nyligen tillagt** bygger på `added` från Xtream eller på när titeln först dök upp vid import.

## 7. Uppspelning [Beslutat om inget annat anges]

### 7.1 Motorer
| | Apples spelare (AVPlayer) | VLC-motorn (VLCKit) |
|---|---|---|
| Format | HLS, MP4/MOV, (TS via HLS) | I princip allt: MKV, AVI, TS, ovanliga kodekar |
| Dolby Vision | Ja | Nej (HDR10 visas, DV-specifik data tappas) |
| HDR10/HLG | Ja | Ja (begränsat) |
| Dolby Atmos | Ja (E-AC-3 JOC) | Begränsat |
| Bild-i-bild, systemkontroller | Ja | Nej / egen UI |
| Undertextformat | WebVTT/inbäddade, externa via egen rendering | SRT, ASS, PGS med flera |

- **Automatiskt läge (standard):** AVPlayer används om container och kodekar stöds (förkontroll via `AVURLAsset` och laddning av `isPlayable`/spår, med en kort timeout). Annars eller vid fel används VLC-motorn utan att användaren behöver göra något.
- Användaren kan välja standardmotor i inställningarna och **byta motor under pågående uppspelning**. Positionen, ljudspåret och textspråket följer med.
- **Informationssida** i inställningarna med tabellen ovan i användarvänlig form.
- **Under uppspelning** finns en info-ruta, till exempel "2160p · Dolby Vision · Atmos · AVPlayer · 18 Mbit/s".
- **Displaymatchning på tvOS:** använd `AVDisplayCriteria` (preferredDisplayCriteria) så att Apple TV:n byter till rätt dynamikomfång och bildfrekvens när "Matcha innehåll" är påslaget.
- Atmos och flerkanalsljud på AVPlayer kräver rätt `AVAudioSession`-konfiguration (`.moviePlayback`, spatial/multichannel).
- **AVPlayer** använder `AVPlayerViewController` för de native kontrollerna. Egna menyer för ljud, text, kvalitet och motor läggs in via `transportBarCustomMenuItems` (tvOS) eller motsvarande.
- **VLC-motorn** får egna SwiftUI-kontroller som ser ut och beter sig så likt systemspelaren som möjligt. Det gäller även svepgester på Siri-fjärrkontrollen.
- En tredje motor (mpv/libplacebo för bättre DV i MKV) är ett **möjligt senare tillägg**. Spelarprotokollet ska göra det enkelt att lägga till en motor.
- Licenser: VLCKit är LGPL och fungerar på App Store. Undvik GPL-beroenden (till exempel KSPlayer i GPL-utgåvan) så att App Store förblir möjligt.

### 7.2 Ljud och undertexter
- **Per profil** finns förvalt ljudspråk med reservordning, förvalt textspråk med lägena av, på och "bara när ljudet är på främmande språk", textutseende (storlek, färg, bakgrund) och "föredra Atmos/surround".
- **Byte** av ljud- och textspår sker i spelarmenyn.
- **OpenSubtitles** [Beslutat]: användaren loggar in med sitt eget konto i inställningarna. Appens API-nyckel är inbyggd (se §3).
  - "Sök fler undertexter…" i spelarmenyn söker på TMDB/IMDb-id samt säsong och avsnitt, och i andra hand på filnamn eller hash.
  - Resultatlistan sorteras på språk, betyg och antal nedladdningar.
  - Återstående dagskvot visas.
- **Externa undertexter:**
  - I AVPlayer renderas de av en egen överlagring (SRT/VTT som tolkas och synkas via en periodisk tidsobservatör).
  - I VLC används `addPlaybackSlave`.
  - **Synkjustering** ± i steg om 0,1 s sparas per titel.
- Nedladdade undertexter sparas per titel och profil och följer med vid offline-nedladdning.

### 7.3 Fortsätt titta och sett-status
- Positionen sparas var 10:e sekund, vid paus och vid avslut. Titeln räknas som sedd vid 90 %, eller när eftertexterna börjar om TMDB-data finns.
- "Nästa avsnitt" visas mot slutet av ett avsnitt med en nedräkning.

## 8. Live TV och TV-tablå

### 8.1 Kanaler
- **Gruppering av kvaliteter** [Beslutat]: kanaler som bara skiljer sig i kvalitetstagg (SD, HD, FHD, UHD, 4K, HDR, 50FPS med flera, plus landsprefix som "SE:" och "SE |") slås ihop till **en kanal med logga**.
  - Högsta kvaliteten väljs automatiskt: 4K/UHD före FHD före HD före SD, och HDR-varianter prioriteras om skärmen stöder HDR.
  - Normaliseringen ska vara testbar med många verkliga namnvarianter i tester.
  - Användaren kan dela upp en felaktig sammanslagning manuellt [Mitt beslut].
- **Kvalitetsmeny i spelaren.** Vid upprepad buffring föreslår appen en lägre kvalitet [Mitt beslut].
- **Loggor** hämtas från `tvg-logo`/`stream_icon`. Saknas logga visas en snygg textlogga som reserv.

### 8.2 Zappa (tvOS)
- I helskärm byter upp/ned kanal. Ett info-overlay visar logga, programmet som sänds nu, nästa program och en tidslinje. Overlayn döljs automatiskt.
- **Kanallistan** (svep eller klick) visar kanalen med fokus med en **liten liveförhandsvisning**, programnamn och beskrivning. Överst finns Favoriter och Senast sedda, därefter kategorier.
- Live spelas alltid i AVPlayer om strömmen är HLS.
- **Mål:** kanalbyte under 2 s, beroende på leverantören. Stäng föregående ström innan nästa öppnas om `max_connections` är 1.

### 8.3 TV-tablå (EPG)
- Rutnät med kanaler vertikalt och tid horisontellt, samt en "nu"-linje. Ett valt program visar namn, beskrivning och tid, med knappen "Titta nu" om programmet sänds.
- **XMLTV** tolkas som ström (SAX, gzip-stöd), och fönstret −1 dag till +7 dagar sparas i databasen. Kanaler kopplas via `tvg-id`/`epg_channel_id`, och i andra hand via normaliserat namn.

## 9. Prestanda – krav [Beslutat som anti-mål; siffrorna är Mitt beslut]

| Mätpunkt | Mål |
|---|---|
| Kallstart till interaktiv Hem (med befintlig data) | < 1 s på Apple TV 4K (3:e gen) |
| Fokusbyte och scroll | Inga tappade bildrutor (60 fps tvOS, 120 fps ProMotion) |
| Artwork vid fokus | Redan i cache för synliga rader och ±1 skärm |
| Förhandsvisning startar | ≈ 1,5 s efter att fokus stannat |
| Sökning i hela biblioteket | < 100 ms per tangenttryck |
| Kanalbyte | < 2 s (beroende på leverantör) |
| Import av 200 000 poster | I bakgrunden, UI:t påverkas inte |

- Ingen nätverksåtkomst eller databasskrivning på huvudtråden. Använd `LazyHStack`/`LazyVStack` eller listor med stabila id:n, och gör inga dyra beräkningar i `body`.
- Prestandatester (XCTest-metrics eller signposts) körs i CI och larmar vid regressioner. Testdata: en genererad spellista med 200 000 poster.
- Animationerna utgår från systemets fokusmotor och fjäderanimationer. Undvik egna "lekfulla" effekter, eftersom anti-målet säger att animationerna inte får kännas löjliga.

## 10. Profiler [Beslutat: profiler per spellista med egen historik och "För dig"]
- Varje profil har namn, avatar, egen historik, Fortsätt titta, Min lista, 👍/👎, ljud- och textinställningar, samt nedladdningar på iOS.
- **Barnprofil** [Mitt beslut]: filtrerar på åldersgräns från TMDB (titlar utan gräns döljs) och döljer Live TV.
- **Valfri PIN** per profil [Mitt beslut].
- Spellistans inloggning delas av alla profiler och lagras i Keychain.

## 11. Nedladdningar (iOS och iPadOS) [Beslutat]
- Film, avsnitt, hel säsong eller "nästa 3 avsnitt".
- `URLSession` i bakgrundsläge, som klarar att appen stängs och låsskärm. Nedladdningarna kan pausas och återupptas. Visa förlopp och utrymme, och ha en inställning för "bara via wifi".
- Undertexter, artwork och metadata sparas med, så att offlineläget ser ut som online.
- Offlineuppspelning använder samma motorlogik: MKV spelas med VLC och MP4 med AVPlayer.
- **Respektera `max_connections`:** nedladdningar köas och pausas när en uppspelning behöver anslutningen [Mitt beslut].
- Valfritt: radera automatiskt när titeln är sedd, och hämta nästa avsnitt automatiskt via wifi [Mitt beslut, valfritt i inställningar].

## 12. Synk mellan enheter (senare fas, kräver betalt konto)
- **CloudKit** (privat databas) synkar profiler, historik, Min lista, betyg och inställningar. Spellistornas inloggningar synkas via iCloud Keychain (`kSecAttrSynchronizable`).
- Datamodellen ska redan från början ha stabila id:n och tidsstämplar, så att synk kan läggas till utan migreringsproblem. Konflikter löses med "senaste skrivning vinner" per fält, och för position "längst kommen".

## 13. Kvalitet, tester och CI
- **Enhetstester** för M3U-, XMLTV- och Xtream-tolkning, normalisering av kanalnamn, titelrensning och TMDB-matchning, rekommendationspoäng och val av spelarmotor. Använd riktiga, anonymiserade exempeldata som fixtures.
- **Snapshot- eller UI-tester** för de viktigaste vyerna på tvOS och iOS [Byggarens val om omfattning].
- **CI:** GitHub Actions med macOS-runner och Xcode 27. Det publika repot ger gratis byggminuter.
  - Varje push kör hemlighetsskanning, genererar projektet, bygger tvOS- och iOS-målen för simulator och kör testerna.
  - Den tunga prestandasviten (200 000 poster) körs på pull requests och varje natt [Mitt beslut].
  - Ett TestFlight-jobb finns men är avstängt tills utvecklarkontot finns.
- Kraschrapportering och loggning sker med `OSLog`/MetricKit. Inga tredjepartsanalyser [Mitt beslut].

## 14. Byggordning (faser) [Mitt beslut]
1. **Grund:** repo, XcodeGen, CI, modulstruktur, databas, Keychain, Xtream- och M3U-import, enkel lista. Verifierat i CI.
2. **tvOS: filmer och serier spelas upp:** spelarprotokoll, AVPlayer- och VLC-motor, automatiskt motorval, ljud och text, Fortsätt titta.
3. **tvOS: Netflix-upplevelsen:** TMDB-metadata, Hem med bakgrund som följer fokus, detaljsida, förhandsvisning, profiler, Min lista, 👍/👎, För dig, Topp 10 och genrer.
4. **Live TV och EPG:** kanalgruppering, zappning, kanallista med förhandsvisning och tablå.
5. **OpenSubtitles.**
6. **iPhone och iPad:** anpassade vyer, bild-i-bild, AirPlay och nedladdningar.
7. **iCloud-synk och TestFlight** (kräver utvecklarkonto).

Varje fas ska resultera i en installerbar app på Apple TV:n.

## 15. Öppna frågor
Inga blockerande. Arbetsnamn tills ägaren väljer ett riktigt namn.
