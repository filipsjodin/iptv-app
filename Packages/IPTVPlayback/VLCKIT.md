# VLCKit

`VLCEngine` använder VLCKit 4.0.0-a25, licensierad under LGPL-2.1 (se `COPYING.txt` i arkivet).

## Original

- URL: `https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip`
  (samma arkiv som VLCKit-taggen `4.0.0-a25` på https://code.videolan.org/videolan/VLCKit pekar ut i sin `Package.swift`).
- SHA-256: `f37c8dbdd4427d1a3f5d75dc4b8bd1ae863cef4426f9a405a2fd1c5c9012f1fb` (922 611 306 byte)
- Speglad oförändrad som release-asset `vlckit-4.0.0-a25` i det här repot.
- Källkod: https://code.videolan.org/videolan/VLCKit (tagg `4.0.0-a25`).

## Ompackad zip (används av `Package.swift`)

- Release-asset `vlckit-4.0.0-a25-slim`, fil `VLCKit-4.0.0-a25-ios-tvos.zip`.
- SHA-256: `22944338b469ce428c0394ceae21222ce9e12c6e7ea67f0acb51f12b5dff209c` (126 979 885 byte)
- Innehåll: skivorna `ios-arm64`, `ios-arm64_x86_64-simulator`, `tvos-arm64` och `tvos-arm64_x86_64-simulator`
  samt `COPYING.txt`. dSYMs och övriga plattformar (macOS, watchOS, visionOS) är borttagna.
- Alla binärer, headers och resurser är byte för byte identiska med originalet. Bara
  `VLCKit.xcframework/Info.plist` är omskriven: den listar de behållna skivorna och saknar `DebugSymbolsPath`.

Binärerna är inte ändrade. `VLCKit.framework` är dynamiskt, så det kan bytas ut mot ett eget bygge av samma version (LGPL-2.1 §6).

### Packa om (reproducerbart)

```sh
curl -fLO https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip
shasum -a 256 VLCKit-4.0-20260929-1631.zip   # f37c8dbd…12f1fb
python3 -I scripts/repack-vlckit.py VLCKit-4.0-20260929-1631.zip VLCKit-4.0.0-a25-ios-tvos.zip
shasum -a 256 VLCKit-4.0.0-a25-ios-tvos.zip
```

Skriptet kopierar varje behållen post med originalets zip-metadata och data, och skriver om `Info.plist` med `plistlib`.
Zip-filens kontrollsumma kan skilja mellan Python/zlib-versioner (komprimeringen), men innehållet blir detsamma;
jämför i så fall filernas SHA-256 mot originalet. Ompackningen ovan gjordes med Python 3.14.4.

## Varför speglad

VLCKit 4 finns bara som alfaversioner (ingen stabil tagg). De officiella arkiven ligger i katalogen `unstable` på
download.videolan.org, som kan rensas. Speglingen gör bygget oberoende av den katalogen och av code.videolan.org.
Den smala zippen minskar nedladdningen i CI från 922 MB till 127 MB.

## Uppdatera

Uppgradera bara till en nyare 4.0-tagg efter en manuell uppspelningskontroll.

1. Ladda ner arkivet som den nya taggens `Package.swift` pekar ut och kontrollera SHA-256 mot den.
2. Packa om med `scripts/repack-vlckit.py` (kontrollera att skivnamnen i `KEEP` fortfarande stämmer).
3. `gh release create vlckit-<version>-slim <zip> --title "..." --notes "..."` med original-URL och båda kontrollsummorna.
4. Uppdatera `url` och `checksum` i `Package.swift`, och den här filen.
