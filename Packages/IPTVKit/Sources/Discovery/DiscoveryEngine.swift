import Foundation
import Core
import Metadata
import Personal

public enum DiscoveryEngine {
    static let genreWeight = 1.0, castWeight = 0.6, directorWeight = 0.8, keywordWeight = 0.4
    static let recommendationBonus = 1.5
    static let watchedThreshold = 0.9

    private static func byPopularity(_ a: Candidate, _ b: Candidate) -> Bool {
        let pa = a.popularity ?? -Double.infinity, pb = b.popularity ?? -Double.infinity
        if pa != pb { return pa > pb }
        return refLess(a.ref, b.ref)
    }

    /// De `k` första elementen i ordningen `before` (samma resultat som `sorted(by:).prefix(k)` för en strikt
    /// total ordning), i O(n log k) i stället för O(n log n).
    static func topK<T>(_ xs: some Sequence<T>, _ k: Int, by before: (T, T) -> Bool) -> [T] {
        guard k > 0 else { return [] }
        var out: [T] = []
        out.reserveCapacity(k + 1)
        for x in xs {
            if out.count == k, !before(x, out[k - 1]) { continue }
            var lo = 0, hi = out.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if before(x, out[mid]) { hi = mid } else { lo = mid + 1 }
            }
            out.insert(x, at: lo)
            if out.count > k { out.removeLast() }
        }
        return out
    }

    public static func forYou(candidates: [Candidate], signals: Signals, limit: Int) -> [ItemRef] {
        // Profilvikt per titel.
        var weights: [ItemRef: Double] = [:]
        for (r, p) in signals.watched where p >= watchedThreshold { weights[r, default: 0] += 1 }
        for (r, rating) in signals.ratings { weights[r, default: 0] += rating == .up ? 2 : -3 }
        for r in signals.myList { weights[r, default: 0] += 1 }
        weights = weights.filter { $0.value != 0 }

        let byRef = Dictionary(candidates.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })

        // Summan av titelvikter per egenskap. Poäng = Σ egenskapsvikt · Σ_titlar vikt · [egenskapen finns i titeln],
        // vilket ger O(n·egenskaper) i stället för O(n·k·egenskaper).
        var genreAgg: [Int: Double] = [:], castAgg: [Int: Double] = [:], dirAgg: [Int: Double] = [:]
        var kwAgg: [String: Double] = [:]
        var recommended = Set<Int>()
        var dislikedTMDB = Set<Int>()
        for (r, w) in weights {
            if let t = byRef[r] {
                for g in Set(t.genres) { genreAgg[g, default: 0] += w }
                for c in Set(t.castIDs) { castAgg[c, default: 0] += w }
                for d in Set(t.directorIDs) { dirAgg[d, default: 0] += w }
                for k in Set(t.keywords) { kwAgg[k, default: 0] += w }
            }
            if w > 0 { recommended.formUnion(signals.recommendationsFor[r] ?? []) }
        }
        for (r, rating) in signals.ratings where rating == .down {
            if let id = byRef[r]?.tmdbID { dislikedTMDB.insert(id) }
        }

        let hasSignals = !weights.isEmpty
        var scored: [(Int, Double)] = []
        scored.reserveCapacity(candidates.count)
        for (index, c) in candidates.enumerated() {
            // För dig visar bara nya titlar: allt med personlig signal hoppas över (men matar profilen).
            if signals.watched[c.ref] != nil || signals.ratings[c.ref] != nil || signals.myList.contains(c.ref) { continue }
            if let id = c.tmdbID, dislikedTMDB.contains(id) { continue }
            var score = 0.0
            if hasSignals {
                for (i, g) in c.genres.enumerated() where !c.genres[..<i].contains(g) { score += genreWeight * (genreAgg[g] ?? 0) }
                for (i, x) in c.castIDs.enumerated() where !c.castIDs[..<i].contains(x) { score += castWeight * (castAgg[x] ?? 0) }
                for (i, d) in c.directorIDs.enumerated() where !c.directorIDs[..<i].contains(d) { score += directorWeight * (dirAgg[d] ?? 0) }
                for (i, k) in c.keywords.enumerated() where !c.keywords[..<i].contains(k) { score += keywordWeight * (kwAgg[k] ?? 0) }
                if let id = c.tmdbID, recommended.contains(id) { score += recommendationBonus }
            }
            scored.append((index, score))
        }
        return topK(scored, limit) { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return byPopularity(candidates[a.0], candidates[b.0])
        }.map { candidates[$0.0].ref }
    }

    public static func topTen(rankedTMDBIDs: [Int], candidates: [Candidate]) -> [ItemRef] {
        var byTMDB: [Int: ItemRef] = [:]
        for c in candidates {
            guard let id = c.tmdbID else { continue }
            if let existing = byTMDB[id], !refLess(c.ref, existing) { continue }
            byTMDB[id] = c.ref
        }
        var out: [ItemRef] = []
        var seen = Set<ItemRef>()
        for id in rankedTMDBIDs {
            guard let r = byTMDB[id], seen.insert(r).inserted else { continue }
            out.append(r)
            if out.count == 10 { break }
        }
        return out
    }

    public static func byGenre(_ genreID: Int, candidates: [Candidate], limit: Int) -> [ItemRef] {
        topK(candidates.lazy.filter { $0.genres.contains(genreID) }, limit, by: byPopularity).map(\.ref)
    }

    public static func recentlyAdded(candidates: [Candidate], limit: Int) -> [ItemRef] {
        topK(candidates.lazy.filter { $0.addedAt != nil }, limit) { a, b in
            if a.addedAt! != b.addedAt! { return a.addedAt! > b.addedAt! }
            return refLess(a.ref, b.ref)
        }.map(\.ref)
    }

    public static func similar(to: Candidate, candidates: [Candidate], tmdbSimilar: [Int], limit: Int) -> [ItemRef] {
        let pool = candidates.filter { $0.ref != to.ref && (to.tmdbID == nil || $0.tmdbID != to.tmdbID) }
        var byTMDB: [Int: Candidate] = [:]
        for c in pool {
            guard let id = c.tmdbID else { continue }
            if let e = byTMDB[id], !refLess(c.ref, e.ref) { continue }
            byTMDB[id] = c
        }
        var out: [ItemRef] = []
        var seen = Set<ItemRef>()
        for id in tmdbSimilar {
            if let c = byTMDB[id], seen.insert(c.ref).inserted { out.append(c.ref) }
        }
        let genres = Set(to.genres), kws = Set(to.keywords)
        var rest: [(Candidate, Double)] = []
        for c in pool where !seen.contains(c.ref) {
            let s = genreWeight * Double(Set(c.genres).intersection(genres).count)
                + keywordWeight * Double(Set(c.keywords).intersection(kws).count)
            if s > 0 { rest.append((c, s)) }
        }
        let remaining = max(0, limit - out.count)
        out.append(contentsOf: topK(rest, remaining) { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return byPopularity(a.0, b.0)
        }.map { $0.0.ref })
        return Array(out.prefix(max(0, limit)))
    }

    public static func byPerson(_ personID: Int, candidates: [Candidate]) -> [ItemRef] {
        candidates.filter { $0.castIDs.contains(personID) || $0.directorIDs.contains(personID) }
            .sorted(by: byPopularity).map(\.ref)
    }

    public static func kidsFilter(_ candidates: [Candidate], maxAge: Int = Certification.kidsMaxAge) -> [Candidate] {
        candidates.filter { c in
            guard let a = c.ageLimit else { return false }
            return a <= maxAge
        }
    }
}
