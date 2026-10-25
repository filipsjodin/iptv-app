# VLCKit

`VLCEngine` använder VLCKit 4.0.0-a25, licensierad under LGPL-2.1 (se `COPYING.txt` i arkivet).

- Original: `https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip`
  (samma arkiv som VLCKit-taggen `4.0.0-a25` på https://code.videolan.org/videolan/VLCKit pekar ut i sin `Package.swift`).
- SHA-256: `f37c8dbdd4427d1a3f5d75dc4b8bd1ae863cef4426f9a405a2fd1c5c9012f1fb`
- Spegling: release-asset `vlckit-4.0.0-a25` i det här repot, byte för byte identisk med originalet.
  `Package.swift` hämtar därifrån med samma kontrollsumma.
- Källkod: https://code.videolan.org/videolan/VLCKit (tagg `4.0.0-a25`).

Binären är inte ändrad. `VLCKit.xcframework` är ett dynamiskt ramverk, så det kan bytas ut mot ett eget bygge av samma version (LGPL-2.1 §6).

## Varför speglad

VLCKit 4 finns bara som alfaversioner (ingen stabil tagg). De officiella arkiven ligger i katalogen `unstable` på
download.videolan.org, som kan rensas. Speglingen gör bygget oberoende av den katalogen och av code.videolan.org.

## Uppdatera

1. Ladda ner det nya arkivet från download.videolan.org och kontrollera SHA-256 mot VLCKit-taggens `Package.swift`.
2. `gh release create vlckit-<version> <zip> --title "VLCKit <version> (LGPL-2.1, unmodified)" --notes "..."`.
3. Uppdatera `url` och `checksum` i `Package.swift`, och den här filen.
