import Foundation
import Core

public enum DownloadPlanner {
    public enum Request: Sendable {
        case movie(String)
        case episode(String, seriesID: String)
        case season(Int, seriesID: String)
        case nextEpisodes(count: Int, after: String?, seriesID: String)
    }

    /// Avsnitts-id i spelordning (säsong, avsnitt, id), utan dubbletter och utan redan hämtade. Total: tomma eller
    /// udda listor ger tomt resultat, aldrig krasch.
    ///
    /// `nextEpisodes`: startpunkten är `after` om den finns bland seriens avsnitt, annars det sista sedda avsnittet
    /// i spelordning, annars början av serien. Därefter tas de första `count` som inte redan är hämtade (över
    /// säsongsgränser, även med luckor i numreringen).
    public static func plan(_ request: Request, episodes: [Episode], alreadyDownloaded: Set<String>,
                            watched: Set<String>) -> [String] {
        switch request {
        case let .movie(id), let .episode(id, _):
            return alreadyDownloaded.contains(id) ? [] : [id]
        case let .season(season, seriesID):
            return ordered(episodes, series: seriesID)
                .filter { $0.season == season && !alreadyDownloaded.contains($0.providerID) }
                .map(\.providerID)
        case let .nextEpisodes(count, after, seriesID):
            guard count > 0 else { return [] }
            let list = ordered(episodes, series: seriesID)
            var start = 0
            if let after, let i = list.firstIndex(where: { $0.providerID == after }) {
                start = i + 1
            } else if let i = list.lastIndex(where: { watched.contains($0.providerID) }) {
                start = i + 1
            }
            return Array(list[start...]
                .filter { !alreadyDownloaded.contains($0.providerID) }
                .prefix(count)
                .map(\.providerID))
        }
    }

    private static func ordered(_ episodes: [Episode], series: String) -> [Episode] {
        var seen = Set<String>()
        return episodes
            .filter { $0.seriesProviderID == series }
            .sorted { ($0.season, $0.number, $0.providerID) < ($1.season, $1.number, $1.providerID) }
            .filter { seen.insert($0.providerID).inserted }
    }
}
