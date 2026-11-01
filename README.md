# iptv-app

IPTV-klient för tvOS och iOS 27. Swift 6 med delade paket.

## Struktur

- `Packages/IPTVKit` – Core, Providers, ProvidersTestSupport, AnonymizeKit och CLI:t `iptv-anonymize`. Kan testas på Windows.
- `Packages/IPTVPlatform` – Library (databas) och Secrets (Keychain). Bara Apple.
- `Apps/project.yml` – XcodeGen-spec för apparna. Scheman: `IPTV-iOS` och `IPTV-tvOS`.
  Bundle-id: `se.sjodin.iptv.ios` och `se.sjodin.iptv.tv` (ändra i `Apps/project.yml` vid behov).

## Kom igång på Windows

Bara `IPTVKit` kan byggas och testas här:

```sh
source scripts/swift-env.sh
cd Packages/IPTVKit && swift test
```

## Kom igång på Mac

Kräver Xcode 27.

```sh
brew install xcodegen gitleaks
cp Apps/Config/Secrets.xcconfig.template Apps/Config/Secrets.xcconfig
xcodegen generate --spec Apps/project.yml
open Apps/IPTV.xcodeproj
```

`Secrets.xcconfig` är gitignorerad. Tomma nycklar betyder att funktionen är avstängd (se nästa avsnitt).
I Xcode: välj ditt Personal Team under Signing & Capabilities för båda målen.
Med gratis Apple-ID kan bundle-id:t behöva göras unikt (t.ex. `se.<ditt-namn>.iptv.tv`).

Tester på Mac:

```sh
(cd Packages/IPTVPlatform && swift test --skip LibraryPerformanceTests)
xcodebuild test -project Apps/IPTV.xcodeproj -scheme IPTV-iOS \
  -destination "platform=iOS Simulator,name=<iPhone-simulator>" CODE_SIGNING_ALLOWED=NO
```

## Nycklar (TMDB/OMDb/OpenSubtitles)

Metadata (beskrivningar, betyg, skådespelare, affischer) och upptäckt som Topp 10 och "För dig" kommer från TMDB.
Utan nyckel fungerar appen ändå, men bara med leverantörens titlar och affischer.

1. Skapa ett gratis konto på [themoviedb.org](https://www.themoviedb.org/signup) och bekräfta e-postadressen.
2. Gå till Inställningar > API ([themoviedb.org/settings/api](https://www.themoviedb.org/settings/api)) och
   ansök om en API-nyckel för personligt, icke-kommersiellt bruk.
3. Kopiera **API Read Access Token** (den långa strängen), inte den korta "API Key".
4. Lägg in den i `Apps/Config/Secrets.xcconfig`:

   ```
   TMDB_READ_TOKEN = <din token>
   ```

5. Valfritt, för IMDb- och Rotten Tomatoes-betyg: hämta en gratis nyckel på
   [omdbapi.com/apikey.aspx](https://www.omdbapi.com/apikey.aspx) och lägg in `OMDB_API_KEY = <din nyckel>`.
6. Valfritt, för undertexter: skapa ett konto på [opensubtitles.com](https://www.opensubtitles.com), registrera ett
   API-consumer under [opensubtitles.com/consumers](https://www.opensubtitles.com/consumers) och lägg in
   `OPENSUBTITLES_API_KEY = <din nyckel>`. Sök och nedladdning kräver dessutom att du loggar in med ditt
   OpenSubtitles-konto under Inställningar (uppgifterna sparas bara i Keychain). Utan nyckel är funktionen
   avstängd, och den finns aldrig i barnprofiler.
7. Kör `xcodegen generate --spec Apps/project.yml` och bygg om. Inställningar i appen visar om TMDB-nyckeln
   saknas, nekas eller hur många titlar som matchats.

Nycklarna hamnar i appens Info.plist (`TMDBReadAccessToken`, `OMDbAPIKey`, `OpenSubtitlesAPIKey`). Checka aldrig in
`Secrets.xcconfig`; i repot finns bara `Secrets.xcconfig.template` med tomma värden.

## Sideload till Apple TV

1. Xcode: Window > Devices and Simulators.
2. På Apple TV:n: Inställningar > Fjärrkontroller och enheter > Fjärrapp och enheter. Para ihop med Macen.
3. Välj schemat `IPTV-tvOS`, välj Apple TV:n som mål och kör.

Med gratis Apple-ID slutar appen fungera efter 7 dagar. Kör då från Xcode igen.

## CI

- `ci.yml`: gitleaks, Kit-tester på Linux och ett Apple-jobb på runnern `xcode-27` (Platform-tester, iOS-tester, tvOS-bygge).
- `nightly.yml`: prestandatester för biblioteket, bland annat fokus till hero på 200 000 titlar (loggas, larmar över 100 ms i medel). Signposts `hero.focus`, `home.firstRows` och `preview.start` kan läsas i Instruments (Points of Interest / os_signpost, subsystem `se.sjodin.iptv`).
- `testflight.yml`: arkiverar och laddar upp till TestFlight, men bara när secrets finns (utan dem är uppladdningen avstängd: en tagg-push blir ett grönt no-op, en manuell körning är en torrkörning som bygger osignerade arkiv). Se "Aktivera iCloud-synk och TestFlight".
- Standardbygget (gratis sideload, ingen synk, inga entitlements) vaktas av steget "Default build has no entitlements and no iCloud sync" i `ci.yml`.

## Aktivera iCloud-synk och TestFlight

Standardbygget (gratis personligt team, sideload) är oförändrat: ingen synk, inga entitlements, inga CloudKit-anrop.
CI vaktar det i `ci.yml`. Synk och TestFlight slås på senare enbart genom att lägga till filer och secrets nedan.
Kräver ett betalt Apple Developer-konto (99 USD/år).

1. På developer.apple.com (Identifiers): skapa app-ID:n `se.sjodin.iptv.ios` och `se.sjodin.iptv.tv` med kapabiliteterna
   iCloud (CloudKit) och Push Notifications, och iCloud-containern `iCloud.se.sjodin.iptv`.
2. Kopiera `Apps/Config/Sync.xcconfig.template` till `Apps/Config/Sync.xcconfig` (gitignorerad) och sätt `DEVELOPMENT_TEAM`
   till det betalda teamet.
3. Kör `xcodegen generate --spec Apps/project.yml` och bygg i Xcode. Filen sätter `ICLOUD_SYNC_ENABLED = YES` och
   `SYNC_ENTITLEMENTS`, så entitlements används.
4. CloudKit-schemat: posttypen `SyncRecord` (fälten `kind`, `key`, `payload`, `updatedAt`, `deleted`, `origin`) i zonen `iptv`
   skapas automatiskt i utvecklingsmiljön när en enhet kör appen första gången. Före TestFlight/App Store: öppna CloudKit
   Dashboard och välj "Deploy Schema Changes" till produktion, annars fungerar inte produktionsbyggen. Lägg till ett
   queryable-index på `recordName` om Dashboard kräver det för hämtning.
5. I appen: Inställningar > iCloud > slå på synk. Valfritt: iCloud Keychain-synk av spellistornas inloggningar (kräver att
   iCloud Keychain är på i iOS-inställningarna). Varning: inloggningar följer då med till alla enheter på samma iCloud-konto,
   och "Ta bort från iCloud" tar bort dem på alla enheter.
6. TestFlight: skapa en App Store Connect API-nyckel (Användare och åtkomst > Integrationer) och lägg i GitHub (Settings >
   Secrets and variables > Actions):
   - `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (hela innehållet i .p8-filen), `APPLE_TEAM_ID`
   - valfritt: `TMDB_READ_TOKEN`, `OMDB_API_KEY`, `OPENSUBTITLES_API_KEY`

   Kör workflowet `testflight` manuellt (Actions > testflight > Run workflow). Torrkörning (`dryRun`, standard) bygger bara
   osignerade arkiv och laddar inte upp; kör den först. Avmarkera `dryRun` för riktig uppladdning, eller pusha en tagg som
   `v0.1.0`. Byggnumret är körningens nummer. Utan alla fyra obligatoriska secrets laddas inget upp: en tagg-push gör ingenting (grönt no-op), en manuell körning är alltid en osignerad torrkörning.

## Testlista fas 7 (två riktiga enheter)

Kräver synkbygge (se ovan) på två enheter med samma iCloud-konto.

- [ ] Profil, historik, Min lista, betyg och inställningar på enhet A syns på enhet B efter synk.
- [ ] Uppspelningsposition: den som kommit längst vinner, även om båda ändrats.
- [ ] Radera en profil på A: den försvinner på B.
- [ ] En enhet som varit offline med gamla data återuppväcker ingen raderad profil eller post när den kommer online.
- [ ] En ny enhet som loggar in på samma konto får inga dubbla profiler.
- [ ] Textförskjutning för undertexter synkar.
- [ ] En spellista från den andra enheten visas som "Inloggning saknas" tills Keychain-synk är på.
- [ ] PIN-skyddad vuxenprofil är låst på en ny enhet tills iCloud Keychain levererat hashen, och en barnprofil kan inte öppna den.
- [ ] Keychain-synk av/på: "Behåll i iCloud" lämnar inloggningarna kvar, "Ta bort från iCloud" tar bort dem på alla enheter.
- [ ] Flygplansläge: ändringar köas och synkas när nätet kommer tillbaka, utan fel kvar.
- [ ] Byte av iCloud-konto (A till B) stoppar synken utan att radera lokal data.
- [ ] Gratis-sideload-bygget (utan `Sync.xcconfig`) fungerar oförändrat.
- [ ] Barnprofil ser inte iCloud-inställningarna.

### Kända begränsningar fas 7

- CloudKit/CKSyncEngine och TestFlight är inte verifierade i CI (ingen container eller konto). Första riktiga körningen kan
  kräva justeringar.
- Inställningar synkas blob-vis (senaste skrivning vinner), inte per fält.
- Framstegsposter lämnar aldrig molnet i form av trimning: bara den lokala listan trimmas till 500.
- Textfiler, nedladdningar, OpenSubtitles-inloggning och PIN-lockout synkas inte.
- Tyst push (`remote-notification`) är inte påslagen i första versionen: fjärrändringar hämtas vid start och förgrund.
- Det finns ingen gravsten för en enskild framstegsnyckel.
- En fjärrspellista utan inloggning visas som "Inloggning saknas" (se ovan).
- Simulatorns Keychain kan göra att synkroniserbara tester hoppas över: verifiera på enhet.
- Kontobyte kräver av/på av synk och omstart av appen.
- Om zonen raderas på servern återskapas den, men ingen automatisk full uppladdning sker.
- Äldre appversioner (nedgradering) läser inte nya personliga nycklar.

## Säkerhet

Repot är publikt. Checka aldrig in spellist-URL:er, användarnamn/lösenord, riktiga spellistor/EPG-filer eller `Secrets.xcconfig`.
Fixtures ska använda `REDACTED` för användarnamn och lösenord. Privat data ligger utanför repot.

Installera pre-commit-hooken: `bash scripts/install-hooks.sh` (kräver `gitleaks`; på Windows `winget install gitleaks`).
Hela historiken kan kontrolleras med `gitleaks detect --config .gitleaks.toml`.

### Anonymisera fixtures

```sh
swift run iptv-anonymize --source <fil> --out <katalog>
```

`<fil>` är en lokal fil utanför repot som innehåller spellist-URL:en. Utdata är maskad, men checka aldrig in rå utdata utan att först köra `gitleaks detect --no-git --source <katalog>`.

## Lagring på tvOS

Biblioteksdatabasen ligger i Caches, som systemet får rensa. Spellistans metadata (utan inloggningsuppgifter) ligger i UserDefaults, så spellistor återställs och importeras om automatiskt efter en cache-rensning. Inloggningsuppgifter ligger i Keychain.

## Testlista för fas 1 på riktig enhet

- [ ] Lägg till din Xtream-spellista på Apple TV:n.
- [ ] Importen slutförs, och menyerna hackar inte under tiden.
- [ ] Antalet filmer, serier och kanaler stämmer ungefär med leverantörens egen app.
- [ ] Sök på "fröken" eller något med å, ä eller ö.
- [ ] Live-fliken: varianterna av samma kanal visas som en kanal.
- [ ] Starta om appen. Allt syns direkt utan ny import.
- [ ] Ta bort spellistan. Den försvinner helt.
- [ ] Apple TV: rensa appens cache (eller vänta på att systemet gör det). Spellistan kommer tillbaka och importeras om automatiskt. Svårt att tvinga fram (ominstallation är inte samma sak), så punkten kan hoppas över.

## Testlista fas 2 (riktig Apple TV)

VLCKit är version 4.0.0-a25 (alpha), pinnad med kontrollsumma. `Packages/IPTVPlayback/VLCKIT.md` beskriver hur den ompackas.

- [ ] En film i .mp4/.m3u8 spelas i Apples spelare, och info-rutan visar motorn.
- [ ] En .mkv-film spelas automatiskt i VLC.
- [ ] Byt motor mitt i en film. Positionen och språket ska följa med.
- [ ] Ljud- och textmenyerna fungerar, och svenska väljs automatiskt enligt inställningarna.
- [ ] 4K Dolby Vision-innehåll: med "Matcha innehåll" påslaget byter TV:n till Dolby Vision, och info-rutan visar "Dolby Vision".
- [ ] Atmos: receivern eller TV:n visar Atmos.
- [ ] Stäng mitt i en film, öppna igen och välj "Fortsätt". Filmen fortsätter där du var.
- [ ] Seriens sista 30 sekunder: "Nästa avsnitt" räknar ner och startar.
- [ ] Live-kanal: bästa kvaliteten väljs, och kanalbytet tar under 2 s.
- [ ] Siri-fjärrkontrollen: svep för att skrubba, och play/paus fungerar i båda motorerna.
- [ ] Inställningar → "Spelarna": jämförelsetabellen visas.
- [ ] Spelaren byter TV-läge (HDR/bildfrekvens) och återställer det när du lämnar uppspelningen.
- [ ] Stäng en VLC-ström från en server som inte svarar – appen fryser inte.
- [ ] Konto med 1 anslutning: VLC-reserv och nästa avsnitt fungerar.
- [ ] VLC-film i 10+ min: skärmsläckaren startar inte.

## Testlista fas 2 (iPhone/iPad)

- [ ] Bild-i-bild: starta en film i Apples spelare, svep hem. Filmen fortsätter i bild-i-bild (pausas inte).
- [ ] AirPlay: skicka till Apple TV, lås telefonen. Uppspelningen fortsätter.
- [ ] Apples helskärmsknapp i spelaren stänger inte uppspelningen.
- [ ] VLC på iPhone: tryck på bilden. Kontrollerna kommer tillbaka.
- [ ] Inställningar → ljudspråk: ändra ordning, starta en film med flera ljudspår. Rätt språk väljs.

## Testlista fas 3a (profiler och metadata)

- [ ] Skapa två profiler och en barnprofil med PIN. Profiler utan PIN öppnas direkt utan fråga.
- [ ] Profilerna har separat historik (Fortsätt titta) och separat Min lista.
- [ ] Barnprofilen visar inget utan åldersgräns och har ingen Live-flik.
- [ ] Fem felaktiga PIN-försök låser inmatningen i 30 sekunder, även om appen startas om.
- [ ] Barnprofilen: Filmer och Serier visar inga kategorier eller "Alla", bara åldersfiltrerade rader. Inställningar
  visar bara "Byt profil".
- [ ] En profil med PIN går inte att ändra eller ta bort (inte heller stänga av PIN eller barnprofil) utan koden.
  Profiler utan PIN är fria att ändra: sätt PIN på vuxenprofilerna för att låsa barnprofilen.
- [ ] Metadata (beskrivning, betyg, skådespelare) dyker upp efter en stund; Inställningar visar antal matchade titlar.
- [ ] För dig ändras efter 👍 (nya titlar liknande den du gillade).
- [ ] Topp 10 visar bara titlar som finns i spellistan.
- [ ] Stäng en film och starta en ny direkt på ett konto med en anslutning. Den nya startar utan fel.
- [ ] En uppspelning tar över en förhandsvisning (testas i 3b).

## Testlista fas 3b (riktig Apple TV)

- [ ] Bläddra genom en rad med fjärrkontrollen: inga hack, bakgrunden byter mjukt.
- [ ] Stanna på en titel: efter cirka 1,5 s tonar förhandsvisningen in (tyst först, sedan ljud om inställningen
  tillåter). Flytta fokus: den stoppas direkt.
- [ ] Titel i MKV eller konto med en anslutning som spelar: artwork visas i stället, ingen förhandsvisning.
- [ ] Stäng av förhandsvisningar/ljud i Inställningar: gäller bara aktiv profil.
- [ ] Detaljsida: Fortsätt-knappen visar rätt avsnitt och tid kvar; 👍/👎 och Min lista syns direkt.
- [ ] Barnprofil: ingen titel utan åldersgräns syns eller förhandsvisas.
- [ ] Slå på Minska rörelse: inga övertoningar till video.
- [ ] Kallstart till Hem under 1 s.
- [ ] Ta bort en spellista som har en vuxenprofil med PIN, utan aktiv vuxenprofil: vuxen-PIN krävs. Med en barnprofil
  aktiv finns inte "Ta bort".

Info-rutan på detaljsidan (utökade uppgifter) kommer i fas 5.

## Tablå (EPG)

Tablån hämtas som XMLTV (gzip stöds) och uppdateras i bakgrunden var 12:e timme; bara −1 till +7 dagar sparas. Kanaler kopplas till program först via `tvg-id` och sedan via namn. Delas en variant upp manuellt (eller spellistan importeras om) nollställs hämtningstiden, så att kopplingen görs om vid nästa uppdatering. Favoriter och senast sedda för en manuellt uppdelad kanal sparas på gruppens id, så att de försvinner om varianten slås ihop igen.

## Testlista fas 4 (Live och tablå, riktig Apple TV)

- [ ] Kanalbyte tar under 2 s från Select till bild.
- [ ] Upp/ned i helskärm zappar mellan kanaler i vald grupp, och infon (kanal, Nu/Nästa) visas kort.
- [ ] Select under pågående live öppnar menyn för ljud, undertext och kvalitet.
- [ ] Kanallistan visar en tyst liveförhandsvisning vid fokus. Kanaler med .ts-ström visar bara bild (ingen VLC i
  förhandsvisning, enligt specen).
- [ ] Buffrar strömmen upprepat visas förslaget om lägre kvalitet; Menu avvisar det utan att stänga uppspelningen.
- [ ] Tablån: nu-linjen står på rätt tid, "Titta nu" finns bara på pågående program, och det går att scrolla
  i 20 000 kanaler utan hack. Fokus hamnar på programcellerna under kanalkolumnen.
- [ ] Tablåns startposition är rätt (nu-linjen nära vänsterkanten). Börjar den cirka 40 min för långt till höger:
  dra av `metrics.leading` i startoffset i `EPGGridView`.
- [ ] Barnprofil: ingen Live-flik och ingen tablå.
- [ ] EPG med gzip från den egna leverantören hämtas och visas (kontrollera Nu/Nästa i kanallistan). Inga adresser
  eller uppgifter får synas i loggar eller fel.
- [ ] Öppna Select-arket under live och stäng det: spelaren fortsätter (stoppas inte av `onDisappear`).

## Testlista fas 5 (Fas 5 på riktig Apple TV, undertexter)

- [ ] Registrera ett OpenSubtitles-konto och en API-nyckel på [opensubtitles.com](https://www.opensubtitles.com). Nyckeln
  läggs bara i `Apps/Config/Secrets.xcconfig` (`OPENSUBTITLES_API_KEY`), aldrig i chatten, koden eller en incheckad fil.
- [ ] Logga in i Inställningar och se dagskvoten.
- [ ] Sök undertext på en film och på ett avsnitt.
- [ ] Svenska tecken (å ä ö) visas rätt.
- [ ] Synkjustering ±0,1 s märks och sparas. Kontrollera riktningen: +0,1 s fördröjer texten.
- [ ] Byt motor mitt i en film och se att texten finns kvar.
- [ ] VLC visar undertexten. Kontrollera spårmappningen efter `addPlaybackSlave`, särskilt för live (TS).
- [ ] tvOS-sökbladet är ett vanligt blad: kontrollera fokus och att Menu-knappen stänger det utan att stoppa uppspelningen.
- [ ] Överlagringens marginaler är rimliga (tvOS 90 pt, iOS 64 pt) och texten klipps inte av skärmkanten.
- [ ] Barnprofil har varken sökning, konto eller info-ruta.
- [ ] Info-rutan visas på detaljsidan efter första uppspelning.
- [ ] Slut dagskvot ger ett vänligt meddelande.

## Testlista fas 6a (riktig iPhone/iPad)

- [ ] iPhone visar en flikrad längst ner. iPad visar en sidomeny som kollapsar när Split View blir smal.
- [ ] Sök-fliken hittar både filmer och serier. En barnprofil ser inga olämpliga träffar och har ingen Live-flik.
- [ ] Affischgriden sidar mjukt utan tomma rutor och byter kolumnantal vid rotation och Split View.
- [ ] Hem-bannern visas utan video och tar ingen anslutning.
- [ ] Detaljsidan startar ingen förhandsvisning själv. Knappen Förhandsvisa startar den tyst, den stoppas när man
  scrollar bort eller lämnar sidan och kan startas igen efter ett misslyckande.
- [ ] AirPlay från Apples spelare (TV/högtalare) fungerar. I VLC visas förklaringen och valet "Byt till Apples spelare".
- [ ] Kontrollcenter, hörlurar och bilen styr VLC: spela, paus, ±15 s och position.
- [ ] Telefonsamtal och hörlursurkoppling pausar VLC, och uppspelningen återupptas inte av sig själv.
- [ ] Spelaren går i liggande helskärm på iPhone och återgår till stående vid stängning. Rotation under uppspelning
  fungerar.
- [ ] Bild-i-bild (Apples spelare) fungerar och tar inga extra anslutningar.
- [ ] Toppmarginalen på Apples spelares överfält är 56 pt i liggande: överlappar våra knappar AVKits egna kontroller?
- [ ] VLC-kontrollerna har 44 pt träffytor.
- [ ] Kanalbytaren ("Kanaler") och svepzappning i live ger haptik. Ingen haptik när en kanal öppnas.
- [ ] iPad: kanallista och tablå visas sida vid sida i bredd läge.
- [ ] Stor textstorlek och VoiceOver fungerar på affischer. Bannerns titel och detaljrad på smal iPhone kan trunkeras.
- [ ] Ögonkolla: grid-sladd när affischen kapas vid 180 pt, och första ramen med bredd 0.
- [ ] Bara på enhet går det att testa PiP, AirPlay, Kontrollcenter och rotation. Simulatorn räcker inte.

## Testlista fas 6b (riktig iPhone/iPad)

- [ ] Ladda ner en film och ett avsnitt: knappen visar förlopp, och ledigt utrymme syns i fliken Nedladdningar.
- [ ] Ladda ner en hel säsong och "nästa 3" avsnitt.
- [ ] Stäng appen och lås skärmen: nedladdningen fortsätter i bakgrunden.
- [ ] Flygplansläge: spela nedladdat offline. MP4 spelas med AVPlayer och MKV med VLC. Undertexter och synk finns kvar, och
  positionen delas med strömning (fortsätt titta fungerar åt båda hållen).
- [ ] Starta en uppspelning medan en nedladdning pågår med `max_connections` = 1: nedladdningen pausar och återupptas
  efteråt.
- [ ] "Bara via wifi" pausar nedladdningen på mobildata och återupptar på wifi.
- [ ] Slut på utrymme ger ett tydligt besked och pausar kön.
- [ ] Döda appen mitt i en nedladdning och starta om: den återupptas eller visar rätt läge.
- [ ] Spellistan uppdateras så att titeln försvinner ur katalogen: nedladdningen finns kvar och kan spelas.
- [ ] Radera spellistan eller profilen: filerna städas bort.
- [ ] Barnprofil har ingen flik Nedladdningar, inga nedladdningsknappar och kan inte spela någon annans nedladdning.
- [ ] Auto-radera sedda och auto nästa avsnitt (kräver wifi) fungerar.
- [ ] Offlinebannern "Du är offline – visar nedladdat" visas efter några sekunder utan nät, blinkar inte vid korta
  bortfall, och försvinner direkt när nätet är tillbaka. Inga felmeddelanden för nätfel medan appen är offline.

### Kända begränsningar fas 6b

- Flaggan "kräver wifi" (automatiskt köade rader) gäller bara för raden; den kan inte ändras per rad i gränssnittet.
- `NWPathMonitor` seedas från aktuell väg vid kallstart: att första läget stämmer är inte verifierat på enhet.
- AVKit och VLC med offline-MKV är inte verifierade på enhet.
- Listan över sedda titlar som väntar på auto-radering ligger bara i minnet: en omstart släpper den.
- Hem-bannerns förhandsvisning är inte kopplad till nedladdade filer.
- Barnprofilens offlineuppspelning misslyckas säkert om katalograden saknas.
- tvOS har inga nedladdningar.

## Licenser

- VLCKit 4.0.0-a25 (LGPL-2.1): används dynamiskt länkad av `VLCEngine` i `Packages/IPTVPlayback`. Binärerna är oförändrade (ompackade, bara iOS/tvOS). Källa och kontrollsummor finns i `Packages/IPTVPlayback/VLCKIT.md`.
- GRDB (MIT): används av `IPTVPlatform` för biblioteksdatabasen.

## Öppet

- Riktiga fixtures saknas: leverantörsservern svarade inte (timeout, CLI-exitkod 2) när `iptv-anonymize` kördes 2026-10-25. Kör om `swift run iptv-anonymize --source <fil> --out <katalog>` när servern nås, kopiera `out/fixtures/*` till `Packages/IPTVKit/Tests/ProvidersTests/Fixtures/real/` efter `gitleaks detect --no-git --source Packages`, och lägg till ett test som kör mappers och `ChannelGrouper` på dem.
