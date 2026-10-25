import Foundation

public struct ProviderCatalog: Sendable, Codable, Hashable {
    public var categories: [Category]
    public var movies: [Movie]
    public var series: [Series]
    public var episodes: [Episode]
    public var live: [LiveStream]

    public init(categories: [Category] = [], movies: [Movie] = [], series: [Series] = [],
                episodes: [Episode] = [], live: [LiveStream] = []) {
        self.categories = categories
        self.movies = movies
        self.series = series
        self.episodes = episodes
        self.live = live
    }
}
