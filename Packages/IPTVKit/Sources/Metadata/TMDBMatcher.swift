import Foundation
import Core
import Providers

public struct MatchResult: Sendable, Equatable {
    public var tmdbID: Int?
    public var confidence: Double
    public init(tmdbID: Int?, confidence: Double) {
        self.tmdbID = tmdbID
        self.confidence = confidence
    }
}

/// Väljer bästa TMDB-kandidat för en städad titel, med konfidens.
public enum TMDBMatcher {
    public static let threshold = 0.75
    /// Två kandidater inom denna marginal räknas som lika bra.
    static let ambiguityMargin = 0.05

    private static let articles: Set<String> = ["the", "a", "an", "en", "ett", "det", "den"]

    public static func match(_ title: CleanTitle, kind: ContentKind, candidates: [TMDBSearchResult]) -> MatchResult {
        let query = normalize(title.title)
        struct Scored {
            let candidate: TMDBSearchResult
            let score: Double
            let yearSupported: Bool
        }
        let scored: [Scored] = candidates.filter { $0.kind == kind }.map { c in
            var sim = ratio(query, normalize(c.title))
            if let original = c.originalTitle { sim = max(sim, ratio(query, normalize(original))) }
            var bonus = 0.0
            var supported = false
            if let wanted = title.year, let year = c.year {
                switch abs(wanted - year) {
                case 0: bonus = 0.15; supported = true
                case 1: bonus = 0.05; supported = true
                default: bonus = -0.25
                }
            }
            return Scored(candidate: c, score: min(1.0, max(0.0, sim + bonus)), yearSupported: supported)
        }
        // Högst poäng först; popularitet bryter bara oavgjort.
        let ranked = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.candidate.popularity > $1.candidate.popularity
        }
        guard let best = ranked.first else { return MatchResult(tmdbID: nil, confidence: 0) }
        guard best.score >= threshold else { return MatchResult(tmdbID: nil, confidence: best.score) }
        if ranked.count > 1 {
            let second = ranked[1]
            if best.score - second.score <= ambiguityMargin, !best.yearSupported, !second.yearSupported {
                return MatchResult(tmdbID: nil, confidence: best.score)
            }
        }
        return MatchResult(tmdbID: best.candidate.id, confidence: best.score)
    }

    /// Titellikhet (0…1) efter normalisering.
    static func similarity(_ a: String, _ b: String) -> Double { ratio(normalize(a), normalize(b)) }

    /// Gemener, diakritiska tecken bortskalade, `&` → `and`, interpunktion borttagen, inledande artikel borttagen
    /// och blanksteg ihopslagna.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .replacingOccurrences(of: "&", with: " and ")
        var cleaned = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) { continue }
            cleaned.unicodeScalars.append(CharacterSet.whitespacesAndNewlines.contains(scalar) ? " " : scalar)
        }
        var words = cleaned.split(separator: " ").map(String.init)
        if words.count > 1, let first = words.first, articles.contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// `1 - levenshtein / maxLen`; två tomma strängar ger 0 (inget att jämföra).
    static func ratio(_ a: String, _ b: String) -> Double {
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 0 }
        return 1 - Double(levenshtein(a, b)) / Double(maxLen)
    }

    /// Levenshtein-avstånd över tecken (ren funktion, två rader minne).
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }
}
