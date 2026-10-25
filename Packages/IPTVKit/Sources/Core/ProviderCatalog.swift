import Foundation

public struct ProviderCatalog: Sendable, Codable, Hashable {
    public var categories: [Category]
    public var movies: [Movie]
    public var series: [Series]
    public var episodes: [Episode]
    public var live: [LiveStream]
    /// `false` när avsnitt hämtas först vid behov (Xtream); `true` när `episodes` är fullständig (M3U).
    public var episodesComplete: Bool

    public init(categories: [Category] = [], movies: [Movie] = [], series: [Series] = [],
                episodes: [Episode] = [], live: [LiveStream] = [], episodesComplete: Bool = true) {
        self.categories = categories
        self.movies = movies
        self.series = series
        self.episodes = episodes
        self.live = live
        self.episodesComplete = episodesComplete
    }

    private enum CodingKeys: String, CodingKey {
        case categories, movies, series, episodes, live, episodesComplete
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = try c.decode([Category].self, forKey: .categories)
        movies = try c.decode([Movie].self, forKey: .movies)
        series = try c.decode([Series].self, forKey: .series)
        episodes = try c.decode([Episode].self, forKey: .episodes)
        live = try c.decode([LiveStream].self, forKey: .live)
        episodesComplete = try c.decodeIfPresent(Bool.self, forKey: .episodesComplete) ?? true
    }
}
