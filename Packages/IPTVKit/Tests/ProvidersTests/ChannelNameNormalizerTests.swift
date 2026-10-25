import Testing
import Foundation
@testable import Providers

private let normalizeCases: [(String, String, String?, VideoQuality, Bool)] = [
    ("SE: TV4 FHD",            "TV4", "SE", VideoQuality.fhd, false),
    ("|SE| TV4 HD",            "TV4", "SE", .hd,  false),
    ("[SE] TV4 4K HDR",        "TV4", "SE", .uhd, true),
    ("SE | TV4 ᵁᴴᴰ",           "TV4", "SE", .uhd, false),
    ("SE - TV4 SD",            "TV4", "SE", .sd,  false),
    ("SVT1 HEVC",              "SVT1", nil, .unknown, false),
    ("UK: Sky Sports F1 UHD",  "Sky Sports F1", "UK", .uhd, false),
    ("AR: الجزيرة HD",          "الجزيرة", "AR", .hd, false),
    ("Kanal Ö ⚽️ FHD 50FPS",    "Kanal Ö ⚽️", nil, .fhd, false),
    ("##### SVERIGE #####",    "##### SVERIGE #####", nil, .unknown, false),
    ("SE: Kanal 5 ᴴᴰ",         "Kanal 5", "SE", .hd, false),
    ("SE: Kanal 9 ᶠᴴᴰ",        "Kanal 9", "SE", .fhd, false),
    ("TV4",                    "TV4", nil, .unknown, false),
    ("HD",                     "HD", nil, .unknown, false),
    ("SE: TV4 - HD",           "TV4", "SE", .hd, false),
    ("SE: TV4 HD HEVC RAW",    "TV4", "SE", .hd, false),
]

@Test(arguments: normalizeCases)
func normalizes(raw: String, base: String, country: String?, q: VideoQuality, hdr: Bool) {
    let n = ChannelNameNormalizer.normalize(raw)
    #expect(n.baseName == base); #expect(n.country == country); #expect(n.quality == q); #expect(n.isHDR == hdr)
}

@Test func groupKeyIgnoresCaseAndSpacing() {
    #expect(ChannelNameNormalizer.normalize("SE: tv4  hd").groupKey == ChannelNameNormalizer.normalize("SE: TV4 4K").groupKey)
}

@Test func groupKeyKeepsDiacritics() {
    #expect(ChannelNameNormalizer.normalize("Kanal Ö").groupKey != ChannelNameNormalizer.normalize("Kanal O").groupKey)
    #expect(ChannelNameNormalizer.normalize("Kanal Ö").groupKey == "kanal ö")
}

@Test func detectsHighFrameRate() {
    #expect(ChannelNameNormalizer.normalize("Eurosport FHD 50FPS").isHighFrameRate)
    #expect(ChannelNameNormalizer.normalize("Eurosport FHD 60FPS").isHighFrameRate)
    #expect(!ChannelNameNormalizer.normalize("Eurosport FHD").isHighFrameRate)
}

@Test func headerNamesAreUntouched() {
    let n = ChannelNameNormalizer.normalize("=== SE: HD ===")
    #expect(n.baseName == "=== SE: HD ===")
    #expect(n.country == nil)
    #expect(n.quality == .unknown)
}

@Test func lowercaseOrAlnumPrefixIsNotACountry() {
    #expect(ChannelNameNormalizer.normalize("TV4 - Nyheter").country == nil)
    #expect(ChannelNameNormalizer.normalize("Sv: Foo").country == nil)
}
