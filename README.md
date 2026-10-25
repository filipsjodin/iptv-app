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

`Secrets.xcconfig` är gitignorerad. API-nycklarna är kommenterade tills de behövs.
I Xcode: välj ditt Personal Team under Signing & Capabilities för båda målen.
Med gratis Apple-ID kan bundle-id:t behöva göras unikt (t.ex. `se.<ditt-namn>.iptv.tv`).

Tester på Mac:

```sh
(cd Packages/IPTVPlatform && swift test --skip LibraryPerformanceTests)
xcodebuild test -project Apps/IPTV.xcodeproj -scheme IPTV-iOS \
  -destination "platform=iOS Simulator,name=<iPhone-simulator>" CODE_SIGNING_ALLOWED=NO
```

## Sideload till Apple TV

1. Xcode: Window > Devices and Simulators.
2. På Apple TV:n: Inställningar > Fjärrkontroller och enheter > Fjärrapp och enheter. Para ihop med Macen.
3. Välj schemat `IPTV-tvOS`, välj Apple TV:n som mål och kör.

Med gratis Apple-ID slutar appen fungera efter 7 dagar. Kör då från Xcode igen.

## CI

- `ci.yml`: gitleaks, Kit-tester på Linux och ett Apple-jobb på runnern `xcode-27` (Platform-tester, iOS-tester, tvOS-bygge).
- `nightly.yml`: prestandatester för biblioteket.
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

## Licenser

- VLCKit 4.0.0-a25 (LGPL-2.1), används dynamiskt länkad av `VLCEngine` i `Packages/IPTVPlayback`. Oförändrad binär, källa och kontrollsumma i `Packages/IPTVPlayback/VLCKIT.md`.

## Öppet

- Riktiga fixtures saknas: leverantörsservern svarade inte (timeout, CLI-exitkod 2) när `iptv-anonymize` kördes 2026-10-25. Kör om `swift run iptv-anonymize --source <fil> --out <katalog>` när servern nås, kopiera `out/fixtures/*` till `Packages/IPTVKit/Tests/ProvidersTests/Fixtures/real/` efter `gitleaks detect --no-git --source Packages`, och lägg till ett test som kör mappers och `ChannelGrouper` på dem.
