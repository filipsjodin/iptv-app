import Testing
import Foundation
import Core
import Providers
@testable import Metadata

struct MatchCase: Sendable, CustomTestStringConvertible {
    struct Candidate: Sendable {
        let title: String
        let year: Int?
        let popularity: Double
        var originalTitle: String? = nil
    }
    let title: String
    let year: Int?
    let candidates: [Candidate]
    /// Index för förväntad kandidat, nil = ingen träff.
    let expected: Int?

    var testDescription: String { "\(title) (\(year.map(String.init) ?? "–"))" }

    var results: [TMDBSearchResult] {
        candidates.enumerated().map { i, c in
            TMDBSearchResult(id: 1000 + i, title: c.title, originalTitle: c.originalTitle, year: c.year,
                             popularity: c.popularity, kind: .movie)
        }
    }
}

private let matchCases: [MatchCase] = [
    MatchCase(title: "Dune: Part Two", year: 2024,
              candidates: [.init(title: "Dune: Part Two", year: 2024, popularity: 500), .init(title: "Dune", year: 2021, popularity: 300)],
              expected: 0),
    MatchCase(title: "Dune", year: nil,
              candidates: [.init(title: "Dune", year: 2021, popularity: 300), .init(title: "Dune", year: 1984, popularity: 40)],
              expected: nil),   // tvetydigt utan år
    MatchCase(title: "Dune", year: 1984,
              candidates: [.init(title: "Dune", year: 2021, popularity: 300), .init(title: "Dune", year: 1984, popularity: 40)],
              expected: 1),
    MatchCase(title: "Bron", year: 2011,
              candidates: [.init(title: "The Bridge", year: 2011, popularity: 50, originalTitle: "Bron")],
              expected: 0),
    MatchCase(title: "Okänd film xyz", year: nil,
              candidates: [.init(title: "Helt annat", year: 2010, popularity: 10)],
              expected: nil),
    MatchCase(title: "Amélie", year: 2001,
              candidates: [.init(title: "Amelie", year: 2001, popularity: 30)],
              expected: 0),   // diakritiska tecken
    MatchCase(title: "Fast & Furious", year: nil,
              candidates: [.init(title: "Fast and Furious", year: 2009, popularity: 30)],
              expected: 0),   // & → and
    MatchCase(title: "Matrix", year: 1999,
              candidates: [.init(title: "The Matrix", year: 1999, popularity: 80)],
              expected: 0),   // inledande artikel
]

@Test(arguments: matchCases)
func matching(_ c: MatchCase) {
    let results = c.results
    let r = TMDBMatcher.match(CleanTitle(title: c.title, year: c.year), kind: .movie, candidates: results)
    #expect(r.tmdbID == c.expected.map { results[$0].id })
    if c.expected != nil { #expect(r.confidence >= TMDBMatcher.threshold && r.confidence <= 1.0) }
}

@Test func ambiguousTitleBelowThresholdIsUnmatched() {
    // "moonwalker" mot "moonshiner": 4 ändringar av 10 → likhet 0,6.
    #expect(abs(TMDBMatcher.similarity("Moonwalker", "Moonshiner") - 0.6) < 0.0001)
    let r = TMDBMatcher.match(CleanTitle(title: "Moonwalker", year: nil), kind: .movie,
                              candidates: [TMDBSearchResult(id: 7, title: "Moonshiner", originalTitle: nil, year: 1988, popularity: 99, kind: .movie)])
    #expect(r.tmdbID == nil)
    #expect(abs(r.confidence - 0.6) < 0.0001)
}

@Test func popularityOnlyBreaksTies() {
    let cands = [TMDBSearchResult(id: 1, title: "Heat", originalTitle: nil, year: 1995, popularity: 10, kind: .movie),
                 TMDBSearchResult(id: 2, title: "Heat", originalTitle: nil, year: 1995, popularity: 90, kind: .movie)]
    #expect(TMDBMatcher.match(CleanTitle(title: "Heat", year: 1995), kind: .movie, candidates: cands).tmdbID == 2)
}

@Test func wrongKindAndEmptyCandidatesAreIgnored() {
    let tv = TMDBSearchResult(id: 5, title: "Bron", originalTitle: nil, year: 2011, popularity: 9, kind: .series)
    #expect(TMDBMatcher.match(CleanTitle(title: "Bron", year: 2011), kind: .movie, candidates: [tv]) == MatchResult(tmdbID: nil, confidence: 0))
    #expect(TMDBMatcher.match(CleanTitle(title: "Bron", year: 2011), kind: .series, candidates: [tv]).tmdbID == 5)
    #expect(TMDBMatcher.match(CleanTitle(title: "Bron", year: nil), kind: .movie, candidates: []) == MatchResult(tmdbID: nil, confidence: 0))
}

@Test func normalizationRules() {
    #expect(TMDBMatcher.normalize("The Lord of the Rings: The Return of the King!") == "lord of the rings the return of the king")
    #expect(TMDBMatcher.normalize("  Én   Ängel  ") == "angel")
    #expect(TMDBMatcher.normalize("Ett päron till farsa") == "paron till farsa")
    #expect(TMDBMatcher.normalize("Tom & Jerry") == "tom and jerry")
    #expect(TMDBMatcher.levenshtein("kitten", "sitting") == 3)
    #expect(TMDBMatcher.levenshtein("", "abc") == 3)
}

@Test func certificationMapping() {
    #expect(Certification.ageLimit(from: ["SE": ["11"], "US": ["PG-13"]]) == ("11", 11))
    #expect(Certification.ageLimit(from: ["SE": ["", "Btl"], "US": ["R"]]) == ("Btl", 0))
    #expect(Certification.ageLimit(from: ["US": ["", "R"]]) == ("R", 17))
    #expect(Certification.ageLimit(from: ["SE": [""], "US": ["NC-17"]]) == ("NC-17", 18))
    #expect(Certification.ageLimit(from: ["US": ["TV-MA"]]) == ("TV-MA", 17))
    #expect(Certification.ageLimit(from: ["US": ["TV-Y7"]]) == ("TV-Y7", 7))
    #expect(Certification.ageLimit(from: ["DE": ["12"]]) == (nil, nil))
    #expect(Certification.ageLimit(from: [:]) == (nil, nil))
    #expect(Certification.ageLimit(from: ["US": ["Unrated"]]) == ("Unrated", nil))
    #expect(Certification.ageLimit(from: ["SE": ["7"]], preferredCountry: "SE", fallback: "US") == ("7", 7))
    let table: [(String, String, Int)] = [("SE", "Btl", 0), ("SE", "7", 7), ("SE", "11", 11), ("SE", "15", 15),
        ("US", "G", 0), ("US", "PG", 7), ("US", "PG-13", 13), ("US", "R", 17), ("US", "NC-17", 18),
        ("US", "TV-Y", 0), ("US", "TV-G", 0), ("US", "TV-Y7", 7), ("US", "TV-PG", 10), ("US", "TV-14", 14), ("US", "TV-MA", 17)]
    for (country, cert, age) in table { #expect(Certification.ageLimit(from: [country: [cert]]).age == age) }
    #expect(Certification.kidsMaxAge == 11)
}
