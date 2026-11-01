import Core
import Foundation
import Testing
@testable import Downloads

/// Mätningar med generösa tak (CI-maskiner varierar). Siffrorna skrivs ut som `PERF ...` för loggen.
@Suite struct DownloadPerformanceTests {
    private static func ms(_ block: () -> Void) -> Double {
        let d = ContinuousClock().measure(block)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    @Test func queueReducer10kEventsFast() {
        let profile = UUID(), playlist = UUID()
        let keys = (0..<200).map {
            DownloadKey(profileID: profile, playlistID: playlist, kind: .movie, providerID: "m\($0)")
        }
        var queue = DownloadQueue(maxConcurrent: 200)
        for key in keys { _ = queue.enqueue(key) }
        let t = Self.ms {
            for i in 0..<10_000 {
                // 10 000 händelser fördelade över 200 hämtande rader; framsteget stiger monotont.
                _ = queue.apply(.progress(keys[i % 200], Double(i / 200) / 50))
            }
        }
        print("PERF download-queue \(String(format: "%.1f", t)) ms")
        #expect(queue.states.count == 200)
        #expect(queue.states[keys[0]] == .downloading(progress: 0.98))
        #expect(t < 300)  // uppmätt ~3 ms; 821 ms var O(n) per händelse
    }

    @Test func plannerLargeSeriesFast() {
        let episodes = (1...500).map {
            Episode(providerID: "e\($0)", seriesProviderID: "S", season: 1, number: $0, title: "T\($0)",
                    locator: .template("{server}/e\($0)"))
        }
        let done = Set((1...100).map { "e\($0)" })
        var season: [String] = []
        var next: [String] = []
        let t = Self.ms {
            season = DownloadPlanner.plan(.season(1, seriesID: "S"), episodes: episodes, alreadyDownloaded: done,
                                          watched: [])
            next = DownloadPlanner.plan(.nextEpisodes(count: 3, after: nil, seriesID: "S"), episodes: episodes,
                                        alreadyDownloaded: done, watched: ["e50"])
        }
        print("PERF download-planner \(String(format: "%.1f", t)) ms")
        #expect(season.count == 400)
        #expect(next == ["e101", "e102", "e103"])
        #expect(t < 2000)  // generöst CI-tak
    }
}
