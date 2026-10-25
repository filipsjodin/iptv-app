import Core
import Foundation

public enum M3UMapper {
    // MARK: - Klassificering

    private static let movieTokens: Set<String> = ["vod", "movie", "movies", "film", "filmer", "films"]
    private static let seriesTokens: Set<String> = ["series", "serier"]
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
        var catalog = ProviderCatalog(episodesComplete: true)
        var categoryKeys: Set<String> = []
        var categoryCounts: [ContentKind: Int] = [:]
        var seriesIndex: [String: Int] = [:]

        func categoryID(_ group: String?, _ kind: ContentKind) -> String? {
            guard let group, !group.isEmpty else { return nil }
            if categoryKeys.insert("\(kind.rawValue)|\(group)").inserted {
                let idx = categoryCounts[kind, default: 0]
                categoryCounts[kind] = idx + 1
                catalog.categories.append(Core.Category(providerID: group, name: group, kind: kind, sortIndex: idx))
            }
            return group
        }

        for entry in playlist.entries {
            var kind = kind(of: entry)
            let group = entry.attributes["group-title"]
            let (locator, id) = mapped(entry.url, secret: secret)
            let logo = nonEmpty(entry.attributes["tvg-logo"]).flatMap { URL(string: $0) }
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

    /// Returnerar en `.xtream`-locator bara när URL:en följer Xtream-mönstret med secretens credentials,
    /// har samma scheme://host[:port] som secretens server (värd utan skiftlägeskänslighet, standardportar
    /// normaliseras) och saknar query/fragment. Annars blir det en `.template` som återger originaladressen.
    /// I templaten ersätts bara hela path-segment och query-värden som är lika med användarnamn/lösenord
    /// (jämförelse efter procent-avkodning); resten av URL:en ändras aldrig. Om en `.m3u`-secret saknar
    /// `username`/`password` i query finns inga credentials att känna igen, och URL:en lagras oförändrad i `.template`.
    public static func locator(for url: String, secret: PlaylistSecret) -> StreamLocator {
        mapped(url, secret: secret).locator
    }

    /// Locator plus ett stabilt providerID: Xtream-formade adresser får alltid stream-id:t som providerID,
    /// oavsett om locatorn blev `.xtream` eller `.template`.
    static func mapped(_ url: String, secret: PlaylistSecret) -> (locator: StreamLocator, providerID: String) {
        let creds = credentials(of: secret)
        let shape = creds.flatMap { xtreamShape(url, user: $0.user, pass: $0.pass) }
        if let shape, isSameServerWithoutExtras(url, secret: secret) {
            return (.xtream(kind: shape.kind, streamID: shape.streamID, container: shape.container), shape.streamID)
        }
        let template = templateLocator(for: url, secret: secret, creds: creds)
        return (template, shape?.streamID ?? providerID(for: template))
    }

    private static func templateLocator(for url: String, secret: PlaylistSecret,
                                        creds: (user: String, pass: String)?) -> StreamLocator {
        var head = ""
        var tail = url
        if let server = serverPrefix(of: secret),
           let r = url.range(of: server, options: [.caseInsensitive, .anchored]) {
            let rest = url[r.upperBound...]
            if rest.isEmpty || rest.first == "/" || rest.first == "?" {
                head = "{server}"
                tail = String(rest)
            }
        }
        guard let creds else { return .template(head + tail) }

        // Hoppa över scheme://authority när servern inte blev platshållare; värden ändras aldrig.
        var authority = ""
        if head.isEmpty, let r = tail.range(of: "://") {
            let after = tail[r.upperBound...]
            let end = after.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? after.endIndex
            authority = String(tail[..<end])
            tail = String(tail[end...])
        }
        var fragment = ""
        if let h = tail.firstIndex(of: "#") {
            fragment = String(tail[h...])
            tail = String(tail[..<h])
        }
        var path = tail
        var query: String?
        if let q = tail.firstIndex(of: "?") {
            path = String(tail[..<q])
            query = String(tail[tail.index(after: q)...])
        }

        func placeholder(_ raw: String) -> String? {
            guard !raw.isEmpty else { return nil }
            let decoded = raw.removingPercentEncoding ?? raw
            if !creds.user.isEmpty && (decoded == creds.user || raw == creds.user) { return "{username}" }
            if !creds.pass.isEmpty && (decoded == creds.pass || raw == creds.pass) { return "{password}" }
            return nil
        }

        let newPath = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { placeholder(String($0)) ?? String($0) }
            .joined(separator: "/")
        var result = head + authority + newPath
        if let query {
            let items: [String] = query.split(separator: "&", omittingEmptySubsequences: false).map { sub in
                let item = String(sub)
                guard let eq = item.firstIndex(of: "=") else { return item }
                let key = String(item[...eq])
                let value = String(item[item.index(after: eq)...])
                return key + (placeholder(value) ?? value)
            }
            result += "?" + items.joined(separator: "&")
        }
        return .template(result + fragment)
    }

    private static func xtreamShape(_ url: String, user: String, pass: String)
        -> (kind: ContentKind, streamID: String, container: String)? {
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
        return (kind, id, container)
    }

    /// Sant när URL:en har samma ursprung (scheme, värd, port) som secretens server, ingen userinfo
    /// och varken query eller fragment. En server med path-prefix räknas aldrig som samma.
    private static func isSameServerWithoutExtras(_ url: String, secret: PlaylistSecret) -> Bool {
        guard let entry = URLComponents(string: url), entry.query == nil, entry.fragment == nil,
              entry.user == nil, entry.password == nil, let a = origin(entry) else { return false }
        let serverURL: URL
        switch secret {
        case let .xtream(server, _, _): serverURL = server
        case let .m3u(u, _): serverURL = u
        }
        guard let server = URLComponents(url: serverURL, resolvingAgainstBaseURL: false), let b = origin(server) else {
            return false
        }
        if case .xtream = secret, !server.path.allSatisfy({ $0 == "/" }) { return false }
        return a == b
    }

    private static func origin(_ c: URLComponents) -> String? {
        guard let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        let port = c.port ?? (scheme == "http" ? 80 : scheme == "https" ? 443 : -1)
        return "\(scheme)://\(host):\(port)"
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
