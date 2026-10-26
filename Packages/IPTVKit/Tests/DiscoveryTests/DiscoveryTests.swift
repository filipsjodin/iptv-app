import Testing
import Foundation
import Core
import Personal
@testable import Discovery

private func ref(_ id: String, _ kind: ContentKind = .movie) -> ItemRef { ItemRef(kind: kind, providerID: id) }

private func cand(_ id: String, tmdb: Int? = nil, genres: [Int] = [], cast: [Int] = [], directors: [Int] = [],
                  keywords: [String] = [], age: Int? = nil, added: Date? = nil, pop: Double? = nil) -> Candidate {
    Candidate(ref: ref(id), tmdbID: tmdb, title: id, genres: genres, castIDs: cast, directorIDs: directors,
              keywords: keywords, ageLimit: age, addedAt: added, popularity: pop)
}

private func signals(watched: [ItemRef: Double] = [:], ratings: [ItemRef: Rating] = [:], myList: Set<ItemRef> = [],
                     recs: [ItemRef: [Int]] = [:]) -> Signals {
    Signals(watched: watched, ratings: ratings, myList: myList, recommendationsFor: recs)
}

@Test func forYouPrefersLikedGenresAndCast() {
    let liked = cand("liked", genres: [1], cast: [10], pop: 100)
    let a = cand("a", genres: [1], cast: [10], pop: 1)
    let b = cand("b", genres: [1], pop: 50)
    let c = cand("c", genres: [2], pop: 99)
    let s = signals(ratings: [liked.ref: .up])
    let r = DiscoveryEngine.forYou(candidates: [c, b, a, liked], signals: s, limit: 10)
    #expect(r == [a.ref, b.ref, c.ref])
}

@Test func forYouExcludesWatchedAndDisliked() {
    let w = cand("w", tmdb: 1, genres: [1])
    let d = cand("d", tmdb: 2, genres: [1])
    let twin = cand("twin", tmdb: 2, genres: [1])
    let partial = cand("partial", genres: [1])
    let ok = cand("ok", genres: [1])
    let s = signals(watched: [w.ref: 0.95, partial.ref: 0.3], ratings: [d.ref: .down])
    let r = DiscoveryEngine.forYou(candidates: [w, d, twin, partial, ok], signals: s, limit: 10)
    #expect(!r.contains(w.ref))
    #expect(!r.contains(d.ref))
    #expect(!r.contains(twin.ref))
    #expect(r.contains(ok.ref))
    #expect(!r.contains(partial.ref))  // har signal (påbörjad), alltså inte ny
}

@Test func forYouUsesTMDBRecommendations() {
    let seed = cand("seed", tmdb: 1, genres: [9])
    let rec = cand("rec", tmdb: 77, genres: [3], pop: 1)
    let other = cand("other", tmdb: 78, genres: [3], pop: 100)
    let s = signals(watched: [seed.ref: 1.0], recs: [seed.ref: [77]])
    let r = DiscoveryEngine.forYou(candidates: [seed, other, rec], signals: s, limit: 10)
    #expect(r.first == rec.ref)
}

@Test func forYouFallsBackToPopularityWithoutSignals() {
    let a = cand("a", pop: 5), b = cand("b", pop: 9), c = cand("c"), d = cand("d")
    let r = DiscoveryEngine.forYou(candidates: [c, a, d, b], signals: signals(), limit: 3)
    #expect(r == [b.ref, a.ref, c.ref])
}

@Test func topTenKeepsRankAndSkipsMissing() {
    let cs = (1...20).filter { $0 != 9 }.map { cand("m\($0)", tmdb: $0) }
    let r = DiscoveryEngine.topTen(rankedTMDBIDs: [5, 1, 9, 2, 3, 4, 6, 7, 8, 10, 11, 12, 13], candidates: cs)
    #expect(r.count == 10)
    #expect(Array(r.prefix(3)) == [ref("m5"), ref("m1"), ref("m2")])
}

@Test func similarExcludesSelfAndPrefersTMDB() {
    let me = cand("me", tmdb: 1, genres: [1, 2], keywords: ["x"])
    let strong = cand("strong", tmdb: 2, genres: [1, 2], keywords: ["x"])
    let tm = cand("tm", tmdb: 3, genres: [8])
    let none = cand("none", tmdb: 4, genres: [7])
    let r = DiscoveryEngine.similar(to: me, candidates: [me, strong, none, tm], tmdbSimilar: [3, 1], limit: 10)
    #expect(r == [tm.ref, strong.ref])
}

@Test func kidsFilterDropsUnratedAndAdult() {
    let r = DiscoveryEngine.kidsFilter([cand("n"), cand("a", age: 15), cand("k", age: 7)])
    #expect(r.map(\.ref) == [ref("k")])
}

@Test func byGenreRecentlyAddedAndPerson() {
    let a = cand("a", genres: [1], cast: [5], added: Date(timeIntervalSince1970: 10), pop: 1)
    let b = cand("b", genres: [1], directors: [5], added: Date(timeIntervalSince1970: 20), pop: 2)
    let c = cand("c", genres: [2], added: nil, pop: 3)
    #expect(DiscoveryEngine.byGenre(1, candidates: [a, b, c], limit: 5) == [b.ref, a.ref])
    #expect(DiscoveryEngine.recentlyAdded(candidates: [a, b, c], limit: 5) == [b.ref, a.ref])
    #expect(DiscoveryEngine.byPerson(5, candidates: [a, b, c]) == [b.ref, a.ref])
}

@Test func deterministicOrdering() {
    let cs = (0..<30).map { cand("id\($0)", genres: [1]) }
    let s = signals(ratings: [ref("id0"): .up])
    let r1 = DiscoveryEngine.forYou(candidates: cs, signals: s, limit: 30)
    let r2 = DiscoveryEngine.forYou(candidates: cs.reversed(), signals: s, limit: 30)
    #expect(r1 == r2)
    #expect(Array(r1.dropFirst()) == r1.dropFirst().sorted(by: refLess))
}

@Test func forYouPerformance() {
    let cs = (0..<120_000).map { i in
        cand("p\(i)", tmdb: i, genres: [i % 20, (i * 7) % 20], cast: [i % 500, i % 311], directors: [i % 90],
             keywords: ["k\(i % 200)", "k\(i % 37)"], pop: Double(i % 1000))
    }
    var ratings: [ItemRef: Rating] = [:]
    for i in 0..<50 { ratings[cs[i].ref] = .up }
    let start = Date()
    let r = DiscoveryEngine.forYou(candidates: cs, signals: signals(ratings: ratings), limit: 50)
    #expect(r.count == 50)
    #expect(Date().timeIntervalSince(start) < 2)
}

@Test func forYouSkipsAllTitlesWithPersonalSignals() {
    let seed = cand("seed", genres: [1])
    let inList = cand("inList", genres: [1])
    let started = cand("started", genres: [1])
    let fresh = cand("fresh", genres: [1])
    let s = signals(watched: [started.ref: 0.2], ratings: [seed.ref: .up], myList: [inList.ref])
    #expect(DiscoveryEngine.forYou(candidates: [seed, inList, started, fresh], signals: s, limit: 10) == [fresh.ref])
}

@Test func forYouMyListWeightIsOne() {
    let listed = cand("listed", genres: [1])
    let g1 = cand("g1", genres: [1], pop: 1)
    let g2 = cand("g2", genres: [2], pop: 99)
    let r = DiscoveryEngine.forYou(candidates: [listed, g1, g2], signals: signals(myList: [listed.ref]), limit: 10)
    #expect(r == [g1.ref, g2.ref])
}

@Test func forYouLimitZeroIsEmpty() {
    #expect(DiscoveryEngine.forYou(candidates: [cand("a", pop: 1)], signals: signals(), limit: 0).isEmpty)
}

@Test func forYouDedupesCandidateFeatures() {
    let liked = cand("liked", genres: [1])
    let dup = cand("dup", genres: [1, 1], pop: 1)
    let single = cand("single", genres: [1, 2], pop: 2)
    let r = DiscoveryEngine.forYou(candidates: [liked, dup, single], signals: signals(ratings: [liked.ref: .up]), limit: 10)
    #expect(r == [single.ref, dup.ref])  // lika poäng (2.0) bryts med popularitet; dup dubbelräknas inte
}

@Test func forYouMatchesBruteForceWithNegativeWeights() {
    var cs: [Candidate] = []
    for i in 0..<40 {
        cs.append(cand("c\(i)", genres: [i % 4, (i + 1) % 4], cast: [i % 5], directors: [i % 3],
                       keywords: ["k\(i % 6)", "k\(i % 2)"], pop: Double(i)))
    }
    let up = [cs[0].ref, cs[1].ref], down = [cs[2].ref, cs[3].ref]
    var ratings: [ItemRef: Rating] = [:]
    up.forEach { ratings[$0] = .up }
    down.forEach { ratings[$0] = .down }
    let watched: [ItemRef: Double] = [cs[1].ref: 1.0, cs[4].ref: 0.95]
    let list: Set<ItemRef> = [cs[4].ref, cs[5].ref]
    let s = signals(watched: watched, ratings: ratings, myList: list)
    var w: [ItemRef: Double] = [:]
    for (r, p) in watched where p >= 0.9 { w[r, default: 0] += 1 }
    for (r, x) in ratings { w[r, default: 0] += x == .up ? 2 : -3 }
    for r in list { w[r, default: 0] += 1 }
    func overlap(_ a: Candidate, _ b: Candidate) -> Double {
        Double(Set(a.genres).intersection(b.genres).count) * 1.0 + Double(Set(a.castIDs).intersection(b.castIDs).count) * 0.6
            + Double(Set(a.directorIDs).intersection(b.directorIDs).count) * 0.8
            + Double(Set(a.keywords).intersection(b.keywords).count) * 0.4
    }
    let signalled = Set(watched.keys).union(ratings.keys).union(list)
    let expected = cs.filter { !signalled.contains($0.ref) }.map { c -> (Candidate, Double) in
        (c, cs.reduce(0.0) { $0 + (w[$1.ref] ?? 0) * overlap(c, $1) })
    }.sorted { a, b in
        if abs(a.1 - b.1) > 1e-9 { return a.1 > b.1 }
        if a.0.popularity != b.0.popularity { return a.0.popularity! > b.0.popularity! }
        return refLess(a.0.ref, b.0.ref)
    }.map(\.0.ref)
    #expect(DiscoveryEngine.forYou(candidates: cs, signals: s, limit: 100) == expected)
}

@Test func kidsFilterKeepsExactlyMaxAge() {
    let r = DiscoveryEngine.kidsFilter([cand("eq", age: 11), cand("over", age: 12)], maxAge: 11)
    #expect(r.map(\.ref) == [ref("eq")])
}
