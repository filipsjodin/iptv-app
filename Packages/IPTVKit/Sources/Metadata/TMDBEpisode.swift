import Foundation

/// Ett avsnitt ur TMDB:s säsongslista: det som detaljsidan visar när leverantören bara har "Serie S01E02".
public struct TMDBEpisodeInfo: Sendable, Equatable {
    public var number: Int
    /// Avsnittets titel. Tom/`nil` när TMDB saknar en riktig (bara "Avsnitt 3").
    public var name: String?
    public var overview: String?
    public var runtimeMinutes: Int?
    /// Sökväg till stillbilden (se `TMDBImage`).
    public var stillPath: String?

    public init(number: Int, name: String? = nil, overview: String? = nil, runtimeMinutes: Int? = nil,
                stillPath: String? = nil) {
        self.number = number
        self.name = name
        self.overview = overview
        self.runtimeMinutes = runtimeMinutes
        self.stillPath = stillPath
    }

    /// TMDB fyller i "Avsnitt 3" / "Episode 3" när titeln saknas på språket: det är ingen riktig titel.
    static func isGeneric(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["avsnitt", "episod", "episode"] where lower.hasPrefix(prefix) {
            let rest = lower.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, rest.allSatisfy(\.isNumber) { return true }
        }
        return false
    }
}

struct TMDBSeasonDTO: Decodable {
    let episodes: [Episode]?

    struct Episode: Decodable {
        let episodeNumber: Int?
        let name: String?
        let overview: String?
        let runtime: Int?
        let stillPath: String?
        enum CodingKeys: String, CodingKey {
            case name, overview, runtime
            case episodeNumber = "episode_number"
            case stillPath = "still_path"
        }
    }

    /// Avsnitt per nummer. Titlar som TMDB bara fyllt i generiskt räknas som saknade.
    func infos() -> [Int: TMDBEpisodeInfo] {
        var result: [Int: TMDBEpisodeInfo] = [:]
        for episode in episodes ?? [] {
            guard let number = episode.episodeNumber else { continue }
            let name = nonEmpty(episode.name).flatMap { TMDBEpisodeInfo.isGeneric($0) ? nil : $0 }
            result[number] = TMDBEpisodeInfo(number: number, name: name, overview: nonEmpty(episode.overview),
                                             runtimeMinutes: episode.runtime.flatMap { $0 > 0 ? $0 : nil },
                                             stillPath: nonEmpty(episode.stillPath))
        }
        return result
    }
}
