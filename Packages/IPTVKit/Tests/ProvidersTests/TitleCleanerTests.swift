import Testing
import Foundation
@testable import Providers

private let titleCases: [(String, String, Int?)] = [
    ("Dune: Part Two (2024) 4K [MULTI-SUB]", "Dune: Part Two", 2024),
    ("SE - Mamma Mia! 2008 1080p",          "Mamma Mia!", 2008),
    ("|EN| Oppenheimer [Dolby Vision]",     "Oppenheimer", nil),
    ("Blade Runner 2049 (2017)",            "Blade Runner 2049", 2017),
    ("1917",                                "1917", nil),
    ("EN: Heat 1995 HEVC HDR",              "Heat", 1995),
    ("Blade Runner 2049",                   "Blade Runner 2049", nil),
    ("IT: Welcome to Derry",                "IT: Welcome to Derry", nil),
    ("Åsa-Nisse (1949)",                    "Åsa-Nisse", 1949),
    ("Movie (1850)",                        "Movie", nil),
    ("[SE] Fast X (2023) [4K] UHD",         "Fast X", 2023),
    ("  Spaced   Out  720p ",               "Spaced   Out", nil),
]

@Test(arguments: titleCases)
func cleansTitles(raw: String, title: String, year: Int?) { #expect(TitleCleaner.clean(raw) == CleanTitle(title: title, year: year)) }

@Test func yearUpperBoundIsCurrentYearPlusOne() {
    let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 UTC
    #expect(TitleCleaner.clean("Film (2028)", now: now) == CleanTitle(title: "Film", year: 2028))
    #expect(TitleCleaner.clean("Film (2029)", now: now) == CleanTitle(title: "Film", year: nil))
    #expect(TitleCleaner.clean("Film 2028", now: now) == CleanTitle(title: "Film", year: 2028))
}

@Test func nonYearTagsAreStripped() {
    #expect(TitleCleaner.clean("Film [MULTI-SUB] (Director's Cut)") == CleanTitle(title: "Film", year: nil))
}
