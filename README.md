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

## Nycklar (TMDB/OMDb)

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
6. Kör `xcodegen generate --spec Apps/project.yml` och bygg om. Inställningar i appen visar om TMDB-nyckeln
   saknas, nekas eller hur många titlar som matchats.

Nycklarna hamnar i appens Info.plist (`TMDBReadAccessToken`, `OMDbAPIKey`). Checka aldrig in
`Secrets.xcconfig`; i repot finns bara `Secrets.xcconfig.template` med tomma värden.

## Sideload till Apple TV

1. Xcode: Window > Devices and Simulators.
2. På Apple TV:n: Inställningar > Fjärrkontroller och enheter > Fjärrapp och enheter. Para ihop med Macen.
3. Välj schemat `IPTV-tvOS`, välj Apple TV:n som mål och kör.

Med gratis Apple-ID slutar appen fungera efter 7 dagar. Kör då från Xcode igen.

## CI

- `ci.yml`: gitleaks, Kit-tester på Linux och ett Apple-jobb på runnern `xcode-27` (Platform-tester, iOS-tester, tvOS-bygge).
- `nightly.yml`: prestandatester för biblioteket, bland annat fokus till hero på 200 000 titlar (loggas, larmar över 100 ms i medel). Signposts `hero.focus`, `home.firstRows` och `preview.start` kan läsas i Instruments (Points of Interest / os_signpost, subsystem `se.sjodin.iptv`).
- TestFlight är inte uppsatt (inget utvecklarkonto än).

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

## Licenser

- VLCKit 4.0.0-a25 (LGPL-2.1): används dynamiskt länkad av `VLCEngine` i `Packages/IPTVPlayback`. Binärerna är oförändrade (ompackade, bara iOS/tvOS). Källa och kontrollsummor finns i `Packages/IPTVPlayback/VLCKIT.md`.
- GRDB (MIT): används av `IPTVPlatform` för biblioteksdatabasen.

## Öppet

- Riktiga fixtures saknas: leverantörsservern svarade inte (timeout, CLI-exitkod 2) när `iptv-anonymize` kördes 2026-10-25. Kör om `swift run iptv-anonymize --source <fil> --out <katalog>` när servern nås, kopiera `out/fixtures/*` till `Packages/IPTVKit/Tests/ProvidersTests/Fixtures/real/` efter `gitleaks detect --no-git --source Packages`, och lägg till ett test som kör mappers och `ChannelGrouper` på dem.
