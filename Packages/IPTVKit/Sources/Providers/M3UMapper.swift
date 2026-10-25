import Core
import Foundation

public enum M3UMapper {
    // MARK: - Klassificering

    private static let movieTokens: Set<String> = ["vod", "movie", "movies", "film", "filmer", "films"]
    private static let seriesTokens: Set<String> = ["series", "serier", "show", "shows"]
    private static let movieExtensions: Set<String> = ["mkv", "mp4", "avi", "mov"]

    public static func kind(of entry: M3UEntry) -> ContentKind {
        let url = entry.url.lowercased()
        if url.contains("/movie/") { return .movie }
        if url.contains("/series/") { return .series }
        if url.contains("/live/") { return .live }

        let group = entry.attributes["group-title"] ?? ""
        let tokens = group.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.contains(where: seriesTokens.contains) { return .series }
        if tokens.contains(where: movieTokens.contains) { return .movie }

        if let ext = pathExtension(of: entry.url), movieExtensions.contains(ext) {
            return SeriesEpisodeParser.parse(entry.title) != nil ? .series : .movie
        }
        return .live
    }

    // MARK: - Katalog

    public static func catalog(from playlist: M3UPlaylist, secret: PlaylistSecret) -> ProviderCatalog {
        var catalog = ProviderCatalog()
        var categoryKeys: Set<String> = []
        var categoryCounts: [ContentKind: Int] = [:]
        var seriesIndex: [String: Int] = [:]

        func categoryID(_ group: String?, _ kind: ContentKind) -> String? {
            guard let group, !group.isEmpty else { return nil }
            if categoryKeys.insert("\(kind.rawValue)|\(group)").inserted {
                let idx = categoryCounts[kind, default: 0]
                categoryCounts[kind] = idx + 1
                catalog.categories.append(Category(providerID: group, name: group, kind: kind, sortIndex: idx))
            }
            return group
        }

        for entry in playlist.entries {
            var kind = kind(of: entry)
            let group = entry.attributes["group-title"]
            let locator = locator(for: entry.url, secret: secret)
            let logo = nonEmpty(entry.attributes["tvg-logo"]).flatMap { URL(string: $0) }
            let id = providerID(for: locator)
            let container = container(of: locator, url: entry.url)

            let episode = kind == .series ? SeriesEpisodeParser.parse(entry.title) : nil
            if kind == .series && episode == nil { kind = .movie }   // serie utan avsnittsnummer: behandla som film

            switch kind {
            case .live:
                catalog.live.append(LiveStream(
                    providerID: id, name: entry.title, categoryID: categoryID(group, .live), logoURL: logo,
                    epgChannelID: nonEmpty(entry.attributes["tvg-id"]), locator: locator))
            case .series:
                guard let ep = episode else { continue }
                let cat = categoryID(group, .series)
                let sid = "m3u:" + fnv1a64Hex(ep.series.lowercased() + "|" + (group ?? ""))
                if let idx = seriesIndex[sid] {
                    if catalog.series[idx].posterURL == nil { catalog.series[idx].posterURL = logo }
                } else {
                    seriesIndex[sid] = catalog.series.count
                    catalog.series.append(Series(providerID: sid, title: ep.series, categoryID: cat, posterURL: logo))
                }
                catalog.episodes.append(Episode(
                    providerID: id, seriesProviderID: sid, season: ep.season, number: ep.episode,
                    title: entry.title, container: container, locator: locator))
            case .movie:
                catalog.movies.append(Movie(
                    providerID: id, title: entry.title, year: trailingYear(entry.title),
                    categoryID: categoryID(group, .movie), posterURL: logo, container: container, locator: locator))
            }
        }
        return catalog
    }

    // MARK: - Locator

    public static func locator(for url: String, secret: PlaylistSecret) -> StreamLocator {
        let creds = credentials(of: secret)
        if let creds, let xt = xtreamLocator(url, user: creds.user, pass: creds.pass) { return xt }

        var head = ""
        var tail = url
        if let server = serverPrefix(of: secret), url.hasPrefix(server) {
            let rest = url.dropFirst(server.count)
            if rest.isEmpty || rest.first == "/" || rest.first == "?" {
                head = "{server}"
                tail = String(rest)
            }
        }
        if let creds {
            // Platshållare ersätter bara delen efter server-prefixet; längsta värdet först.
            let pairs = [(creds.user, "{username}"), (creds.pass, "{password}")]
                .filter { !$0.0.isEmpty }
                .sorted { $0.0.count > $1.0.count }
            for (value, placeholder) in pairs {
                for variant in [encode(value), value] where !variant.isEmpty {
                    tail = tail.replacingOccurrences(of: variant, with: placeholder)
                }
            }
        }
        return .template(head + tail)
    }

    private static func xtreamLocator(_ url: String, user: String, pass: String) -> StreamLocator? {
        guard let comps = URLComponents(string: url) else { return nil }
        let segs = comps.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        var kind: ContentKind = .live
        var rest = segs[...]
        if segs.count == 4, let k = ContentKind(rawValue: segs[0]) {
            kind = k
            rest = segs.dropFirst()
        } else if segs.count != 3 {
            return nil
        }
        let s = rest.startIndex
        guard rest.count == 3, rest[s] == user, rest[s + 1] == pass else { return nil }
        let file = rest[s + 2]
        let id: String
        var ext: String?
        if let dot = file.lastIndex(of: "."), dot != file.startIndex {
            id = String(file[..<dot])
            ext = String(file[file.index(after: dot)...]).lowercased()
        } else {
            id = file
        }
        guard !id.isEmpty else { return nil }
        let container = (ext?.isEmpty == false ? ext! : (kind == .live ? "ts" : "mp4"))
        return .xtream(kind: kind, streamID: id, container: container)
    }

    private static func credentials(of secret: PlaylistSecret) -> (user: String, pass: String)? {
        switch secret {
        case let .xtream(_, username, password):
            return (username, password)
        case let .m3u(url, _):
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let u = items.first(where: { $0.name == "username" })?.value,
                  let p = items.first(where: { $0.name == "password" })?.value else { return nil }
            return (u, p)
        }
    }

    private static func serverPrefix(of secret: PlaylistSecret) -> String? {
        switch secret {
        case let .xtream(server, _, _):
            var s = server.absoluteString
            while s.hasSuffix("/") { s.removeLast() }
            return s
        case let .m3u(url, _):
            guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = c.scheme, let host = c.host else { return nil }
            return "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
        }
    }

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    // MARK: - Hjälpare

    private static func providerID(for locator: StreamLocator) -> String {
        switch locator {
        case let .xtream(_, streamID, _): return streamID
        case let .template(t): return "m3u:" + fnv1a64Hex(t)
        }
    }

    private static func container(of locator: StreamLocator, url: String) -> String? {
        if case let .xtream(_, _, c) = locator { return c }
        return pathExtension(of: url)
    }

    private static func pathExtension(of url: String) -> String? {
        var path = Substring(url)
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<q] }
        guard let slash = path.lastIndex(of: "/"), let dot = path.lastIndex(of: "."), dot > slash else { return nil }
        let ext = path[path.index(after: dot)...].lowercased()
        return ext.isEmpty ? nil : ext
    }

    private static func trailingYear(_ title: String) -> Int? {
        guard title.hasSuffix(")"), let open = title.lastIndex(of: "(") else { return nil }
        let inner = title[title.index(after: open)..<title.index(before: title.endIndex)]
        guard inner.count == 4, let y = Int(inner), (1880...2100).contains(y) else { return nil }
        return y
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// FNV-1a 64-bit, hex (16 tecken). Stabil mellan körningar, till skillnad från `hashValue`.
    static func fnv1a64Hex(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
