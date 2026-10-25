import Foundation
import Core

enum XtreamMapper {
    /// Behåller första förekomsten per providerID.
    static func dedupe<E>(_ items: [E], by id: (E) -> String) -> [E] {
        var seen = Set<String>()
        return items.filter { seen.insert(id($0)).inserted }
    }

    static func url(_ s: String?) -> URL? {
        guard let s, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    static func date(_ unix: Int?) -> Date? {
        guard let unix, unix > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    static func categories(_ rows: [XtreamCategoryDTO], kind: ContentKind) -> [Category] {
        var result: [Category] = []
        for row in rows {
            guard let id = row.categoryID, let name = row.categoryName else { continue }
            result.append(Category(providerID: id, name: name, kind: kind, sortIndex: result.count))
        }
        return dedupe(result, by: { $0.providerID })
    }

    static func movies(_ rows: [XtreamVodDTO]) -> [Movie] {
        dedupe(rows.compactMap { r in
            guard let id = r.streamID, let name = r.name else { return nil }
            let container = r.containerExtension ?? "mp4"
            return Movie(providerID: id, title: name, year: r.year, categoryID: r.categoryID,
                         posterURL: url(r.streamIcon), container: container, tmdbID: r.tmdb,
                         rating: r.rating, addedAt: date(r.added),
                         locator: .xtream(kind: .movie, streamID: id, container: container))
        }, by: { $0.providerID })
    }

    static func series(_ rows: [XtreamSeriesDTO]) -> [Series] {
        dedupe(rows.compactMap { r in
            guard let id = r.seriesID, let name = r.name else { return nil }
            return Series(providerID: id, title: name, year: r.year, categoryID: r.categoryID,
                          posterURL: url(r.cover), tmdbID: r.tmdb, rating: r.rating,
                          addedAt: date(r.lastModified))
        }, by: { $0.providerID })
    }

    static func live(_ rows: [XtreamLiveDTO], container: String) -> [LiveStream] {
        dedupe(rows.compactMap { r in
            guard let id = r.streamID, let name = r.name else { return nil }
            return LiveStream(providerID: id, name: name, categoryID: r.categoryID,
                              logoURL: url(r.streamIcon), epgChannelID: r.epgChannelID,
                              locator: .xtream(kind: .live, streamID: id, container: container))
        }, by: { $0.providerID })
    }

    static func episodes(_ info: XtreamSeriesInfoResponse, seriesID: String) -> [Episode] {
        var result: [Episode] = []
        for (index, group) in info.groups.enumerated() {
            for row in group.rows {
                guard let id = row.id else { continue }
                let season = group.season ?? row.season ?? (index + 1)
                let container = row.containerExtension ?? "mp4"
                let number = row.episodeNum ?? 0
                result.append(Episode(providerID: id, seriesProviderID: seriesID, season: season, number: number,
                                      title: row.title ?? "Episode \(number)", container: container,
                                      locator: .xtream(kind: .series, streamID: id, container: container)))
            }
        }
        return dedupe(result.sorted { ($0.season, $0.number, $0.providerID) < ($1.season, $1.number, $1.providerID) }, by: { $0.providerID })
    }
}
