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

    /// Frågeparametrar som kan bära leverantörens uppgifter. En adress med någon av dem sparas aldrig.
    private static let credentialQueryNames: Set<String> = [
        "username", "user", "password", "pass", "passwd", "token", "key", "api_key", "apikey", "access_token", "auth",
    ]

    /// Bara `http`/`https` med värd, utan användaruppgifter i adressen och utan frågeparametrar som ser ut som
    /// uppgifter; annars `nil` (hellre avvisa än rensa, så att en sparad adress aldrig bär leverantörens uppgifter).
    static func httpURL(_ s: String?) -> URL? {
        guard let u = url(s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return nil }
        let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard !items.contains(where: { credentialQueryNames.contains($0.name.lowercased()) }) else { return nil }
        return u
    }

    /// Längd i sekunder: `duration_secs` först, annars `HH:MM:SS` eller `MM:SS`. Noll, negativt och över 24 h ger `nil`.
    static func durationSeconds(secs: Int?, text: String?) -> Int? {
        func valid(_ v: Int) -> Int? { v > 0 && v <= 86_400 ? v : nil }
        if let secs, let v = valid(secs) { return v }
        guard let text else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let n = parts.compactMap { $0 }
        let total = n.count == 3 ? n[0] * 3600 + n[1] * 60 + n[2] : n[0] * 60 + n[1]
        return valid(total)
    }

    static func date(_ unix: Int?) -> Date? {
        guard let unix, unix > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    static func categories(_ rows: [XtreamCategoryDTO], kind: ContentKind) -> [Core.Category] {
        var result: [Core.Category] = []
        for row in rows {
            guard let id = row.categoryID, let name = row.categoryName else { continue }
            result.append(Core.Category(providerID: id, name: name, kind: kind, sortIndex: result.count))
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
                                      locator: .xtream(kind: .series, streamID: id, container: container),
                                      stillURL: httpURL(row.info?.movieImage), overview: row.info?.plot,
                                      durationSeconds: durationSeconds(secs: row.info?.durationSecs,
                                                                       text: row.info?.duration)))
            }
        }
        return dedupe(result.sorted { ($0.season, $0.number, $0.providerID) < ($1.season, $1.number, $1.providerID) }, by: { $0.providerID })
    }
}
