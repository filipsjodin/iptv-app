import Foundation
import Testing
@testable import Downloads
import Core

private func ep(_ id: String, s: Int, n: Int, series: String = "S") -> Episode {
    Episode(providerID: id, seriesProviderID: series, season: s, number: n, title: "T\(id)",
            locator: .template("{server}/\(id)"))
}

@Suite struct DownloadPlannerTests {
    // Medvetet blandad ordning.
    let eps = [ep("s2e1", s: 2, n: 1), ep("s1e2", s: 1, n: 2), ep("s1e1", s: 1, n: 1),
               ep("s2e2", s: 2, n: 2), ep("s3e1", s: 3, n: 1), ep("other", s: 1, n: 1, series: "X")]

    @Test func seasonExpandsInOrderSkippingDownloaded() {
        let r = DownloadPlanner.plan(.season(1, seriesID: "S"), episodes: eps, alreadyDownloaded: ["s1e1"], watched: [])
        #expect(r == ["s1e2"])
        let all = DownloadPlanner.plan(.season(2, seriesID: "S"), episodes: eps, alreadyDownloaded: [], watched: [])
        #expect(all == ["s2e1", "s2e2"])
    }

    @Test func nextThreeStartsAfterLastWatchedOrGivenEpisode() {
        let afterWatched = DownloadPlanner.plan(.nextEpisodes(count: 3, after: nil, seriesID: "S"), episodes: eps,
                                                alreadyDownloaded: [], watched: ["s1e1"])
        #expect(afterWatched == ["s1e2", "s2e1", "s2e2"])
        let afterGiven = DownloadPlanner.plan(.nextEpisodes(count: 3, after: "s1e2", seriesID: "S"), episodes: eps,
                                              alreadyDownloaded: ["s2e1"], watched: ["s1e1"])
        #expect(afterGiven == ["s2e2", "s3e1"])
        let none = DownloadPlanner.plan(.nextEpisodes(count: 2, after: nil, seriesID: "S"), episodes: eps,
                                        alreadyDownloaded: [], watched: [])
        #expect(none == ["s1e1", "s1e2"])
    }

    @Test func nextEpisodesCrossesSeasonBoundary() {
        let r = DownloadPlanner.plan(.nextEpisodes(count: 2, after: "s2e2", seriesID: "S"), episodes: eps,
                                     alreadyDownloaded: [], watched: [])
        #expect(r == ["s3e1"])
        let gap = [ep("a", s: 1, n: 3), ep("b", s: 4, n: 1)]
        #expect(DownloadPlanner.plan(.nextEpisodes(count: 1, after: "a", seriesID: "S"), episodes: gap,
                                     alreadyDownloaded: [], watched: []) == ["b"])
    }

    @Test func nextEpisodesStopsAtEndOfSeries() {
        let r = DownloadPlanner.plan(.nextEpisodes(count: 5, after: "s3e1", seriesID: "S"), episodes: eps,
                                     alreadyDownloaded: [], watched: [])
        #expect(r.isEmpty)
        #expect(DownloadPlanner.plan(.nextEpisodes(count: 0, after: nil, seriesID: "S"), episodes: eps,
                                     alreadyDownloaded: [], watched: []).isEmpty)
        #expect(DownloadPlanner.plan(.nextEpisodes(count: -3, after: nil, seriesID: "S"), episodes: eps,
                                     alreadyDownloaded: [], watched: []).isEmpty)
    }

    @Test func movieAndEpisodePlanSingle() {
        #expect(DownloadPlanner.plan(.movie("m1"), episodes: [], alreadyDownloaded: [], watched: []) == ["m1"])
        #expect(DownloadPlanner.plan(.movie("m1"), episodes: [], alreadyDownloaded: ["m1"], watched: []).isEmpty)
        #expect(DownloadPlanner.plan(.episode("s1e1", seriesID: "S"), episodes: eps, alreadyDownloaded: [], watched: []) == ["s1e1"])
        #expect(DownloadPlanner.plan(.episode("s1e1", seriesID: "S"), episodes: eps, alreadyDownloaded: ["s1e1"], watched: []).isEmpty)
    }

    @Test func plannerIsTotalOnOddInput() {
        #expect(DownloadPlanner.plan(.season(1, seriesID: "S"), episodes: [], alreadyDownloaded: [], watched: []).isEmpty)
        #expect(DownloadPlanner.plan(.season(9, seriesID: "S"), episodes: eps, alreadyDownloaded: [], watched: []).isEmpty)
        let dups = [ep("a", s: 1, n: 1), ep("a", s: 1, n: 1), ep("b", s: 1, n: 1), ep("c", s: 1, n: 2)]
        let r = DownloadPlanner.plan(.season(1, seriesID: "S"), episodes: dups, alreadyDownloaded: [], watched: [])
        #expect(r == ["a", "b", "c"])
        // Okänt "after"-id behandlas som utan.
        #expect(DownloadPlanner.plan(.nextEpisodes(count: 1, after: "zzz", seriesID: "S"), episodes: eps,
                                     alreadyDownloaded: [], watched: []) == ["s1e1"])
        // Sedda avsnitt (även okända id) påverkar startpunkten utan att krascha.
        let seen = DownloadPlanner.plan(.nextEpisodes(count: 9, after: nil, seriesID: "S"), episodes: eps,
                                        alreadyDownloaded: [], watched: ["s2e1", "ghost"])
        #expect(seen == ["s2e2", "s3e1"])
    }
}
