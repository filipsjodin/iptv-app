import Foundation
import Core
import Providers
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public let placeholderHost = "example.invalid"
public let maxFixtureItems = 300
/// Värdar som får förekomma i fixtures utöver `example.invalid`.
public let allowedFixtureHosts: Set<String> = [placeholderHost, "image.tmdb.org"]

public struct CLIFailure: Error {
    public let code: Int32
    public let message: String
    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Källa

/// Källfilen ska ha exakt en icke-tom rad (BOM tas bort). Felmeddelanden nämner aldrig innehållet.
public func parseSource(_ text: String) throws -> PlaylistSecret {
    let cleaned = text.replacingOccurrences(of: "\u{FEFF}", with: "")
    let lines = cleaned.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard lines.count == 1 else {
        throw CLIFailure(code: 65, message: "Källfilen ska innehålla exakt en rad med en URL.")
    }
    guard let url = URL(string: lines[0]),
          let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = c.scheme, ["http", "https"].contains(scheme.lowercased()), let host = c.host else {
        throw CLIFailure(code: 65, message: "Källfilen innehåller ingen giltig http(s)-URL.")
    }
    let items = c.queryItems ?? []
    let user = items.first { $0.name == "username" }?.value
    let pass = items.first { $0.name == "password" }?.value
    var segments = c.path.split(separator: "/").map(String.init)
    let last = segments.last ?? ""
    let isXtreamPath = ["player_api.php", "get.php", "xmltv.php"].contains(last.lowercased())
    let isBareServer = segments.isEmpty

    if isXtreamPath || (isBareServer && user != nil && pass != nil) {
        guard let user, let pass, !user.isEmpty, !pass.isEmpty else {
            throw CLIFailure(code: 65, message: "Xtream-URL:en saknar username och/eller password.")
        }
        if isXtreamPath { segments.removeLast() }
        var server = URLComponents()
        server.scheme = scheme
        server.host = host
        server.port = c.port
        server.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard let serverURL = server.url else { throw CLIFailure(code: 65, message: "Ogiltig serveradress.") }
        return .xtream(server: serverURL, username: user, password: pass)
    }
    return .m3u(url: url, epgURL: nil)
}

/// Sant om någon inloggningsuppgift är så kort att redigering kan förstöra utdata.
public func hasShortCredentials(_ secret: PlaylistSecret) -> Bool {
    switch secret {
    case let .xtream(_, u, p): return u.count < 4 || p.count < 4
    case let .m3u(url, _):
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.filter { $0.name == "username" || $0.name == "password" }.contains { ($0.value ?? "").count < 4 }
    }
}

// MARK: - Hjälpfunktioner

public func percent(_ n: Int, of total: Int) -> String {
    guard total > 0 else { return "0.0" }
    let tenths = (n * 1000 + total / 2) / total
    return "\(tenths / 10).\(tenths % 10)"
}

public func isUnreachable(_ error: Error) -> Bool {
    if let p = error as? ProviderError, p == .unreachable { return true }
    guard let u = error as? URLError else { return false }
    return [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
            .notConnectedToInternet, .dnsLookupFailed].contains(u.code)
}

// MARK: - Fixtures

public func anonymizedAsset(_ url: URL?) -> URL? {
    guard let url else { return nil }
    let name = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? "x" : url.lastPathComponent
    return URL(string: "https://\(placeholderHost)/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "x"))
}

/// Skriver om en mall-locator: host blir `example.invalid`, path-segment efter det första behålls bara om de är
/// numeriska id:n, platshållare eller filnamn med ändelse, och query-värden blir `REDACTED`.
public func anonymizedTemplate(_ template: String) -> String {
    var rest = template
    var head = ""
    if rest.hasPrefix("{server}") {
        head = "{server}"
        rest.removeFirst(head.count)
    } else if let r = rest.range(of: "://") {
        let after = rest[r.upperBound...]
        let end = after.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? after.endIndex
        head = "http://\(placeholderHost)"
        rest = String(after[end...])
    }
    if let h = rest.firstIndex(of: "#") { rest = String(rest[..<h]) }
    var path = rest
    var query: String?
    if let q = rest.firstIndex(of: "?") {
        path = String(rest[..<q])
        query = String(rest[rest.index(after: q)...])
    }
    func keep(_ s: String) -> Bool {
        if s.hasPrefix("{") && s.hasSuffix("}") { return true }
        if !s.isEmpty && s.allSatisfy(\.isNumber) { return true }
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return false }
        let ext = s[s.index(after: dot)...]
        return !ext.isEmpty && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }
    var index = 0
    let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { seg -> String in
        let s = String(seg)
        if s.isEmpty { return s }
        index += 1
        return index == 1 || keep(s) ? s : Redactor.placeholder
    }
    var result = head + segments.joined(separator: "/")
    if let query {
        let pairs = query.split(separator: "&").map { pair -> String in
            guard let eq = pair.firstIndex(of: "=") else { return String(pair) }
            return String(pair[..<eq]) + "=" + Redactor.placeholder
        }
        result += "?" + pairs.joined(separator: "&")
    }
    return result
}

public func fixtureCatalog(_ c: ProviderCatalog) -> ProviderCatalog {
    var movies = Array(c.movies.prefix(maxFixtureItems))
    var series = Array(c.series.prefix(maxFixtureItems))
    var live = Array(c.live.prefix(maxFixtureItems))
    var episodes = Array(c.episodes.prefix(maxFixtureItems))
    func rewrite(_ l: StreamLocator) -> StreamLocator {
        if case let .template(t) = l { return .template(anonymizedTemplate(t)) }
        return l
    }
    for i in movies.indices {
        movies[i].posterURL = anonymizedAsset(movies[i].posterURL)
        movies[i].locator = rewrite(movies[i].locator)
    }
    for i in series.indices { series[i].posterURL = anonymizedAsset(series[i].posterURL) }
    for i in live.indices {
        live[i].logoURL = anonymizedAsset(live[i].logoURL)
        live[i].locator = rewrite(live[i].locator)
    }
    for i in episodes.indices { episodes[i].locator = rewrite(episodes[i].locator) }
    return ProviderCatalog(categories: Array(c.categories.prefix(maxFixtureItems)), movies: movies, series: series,
                           episodes: episodes, live: live)
}

/// Direktlänk med platshållarinloggning, host `example.invalid` och utan query, userinfo, port eller fragment.
public func placeholderURL(_ locator: StreamLocator) -> String {
    let placeholder = PlaylistSecret.xtream(server: URL(string: "http://\(placeholderHost)")!,
                                            username: "REDACTED", password: "REDACTED")
    guard let url = try? locator.resolve(with: placeholder),
          var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "http://\(placeholderHost)/" }
    c.host = placeholderHost
    c.port = nil
    c.user = nil
    c.password = nil
    c.query = nil
    c.fragment = nil
    return c.string ?? "http://\(placeholderHost)/"
}

public func sampleM3U(_ c: ProviderCatalog) -> String {
    let names = Dictionary(c.categories.map { ("\($0.kind.rawValue)|\($0.providerID)", $0.name) }, uniquingKeysWith: { a, _ in a })
    func entry(kind: ContentKind, title: String, categoryID: String?, tvgID: String? = nil, locator: StreamLocator) -> String {
        var attrs = ""
        if let tvgID, !tvgID.isEmpty { attrs += " tvg-id=\"\(tvgID.replacingOccurrences(of: "\"", with: "'"))\"" }
        if let categoryID {
            let g = names["\(kind.rawValue)|\(categoryID)"] ?? categoryID
            attrs += " group-title=\"\(g.replacingOccurrences(of: "\"", with: "'"))\""
        }
        let safeTitle = title.replacingOccurrences(of: "\n", with: " ")
        return "#EXTINF:-1\(attrs),\(safeTitle)\n\(placeholderURL(locator))"
    }
    var lines = ["#EXTM3U"]
    lines += c.live.map { entry(kind: .live, title: $0.name, categoryID: $0.categoryID, tvgID: $0.epgChannelID, locator: $0.locator) }
    lines += c.movies.map { entry(kind: .movie, title: $0.title, categoryID: $0.categoryID, locator: $0.locator) }
    lines += c.episodes.map { entry(kind: .series, title: $0.title, categoryID: nil, locator: $0.locator) }
    return lines.joined(separator: "\n") + "\n"
}

/// Fixturefilerna (namn och text) för katalogen, efter `fixtureCatalog`.
public func renderFixtures(_ catalog: ProviderCatalog) throws -> [(name: String, text: String)] {
    let fx = fixtureCatalog(catalog)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    func json<T: Encodable>(_ value: T, _ name: String) throws -> (name: String, text: String) {
        (name, String(decoding: try encoder.encode(value), as: UTF8.self))
    }
    return [
        try json(fx.categories, "categories.json"),
        try json(fx.movies, "movies.json"),
        try json(fx.series, "series.json"),
        try json(fx.episodes, "episodes.json"),
        try json(fx.live, "live.json"),
        ("sample.m3u", sampleM3U(fx)),
    ]
}

// MARK: - Läckagevakt

private let urlHostRegex = try! NSRegularExpression(pattern: #"https?:(?:\\)?/(?:\\)?/([^/\s"'\\?#]*)"#, options: [.caseInsensitive])
private let ipv4Regex = try! NSRegularExpression(pattern: #"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])"#)

/// Antal misstänkta träffar: URL:er med annan host än de tillåtna samt IPv4-adresser. Returnerar aldrig träffarna.
public func fixtureLeaks(in text: String) -> Int {
    let ns = text as NSString
    let whole = NSRange(location: 0, length: ns.length)
    var count = 0
    for m in urlHostRegex.matches(in: text, range: whole) {
        let host = ns.substring(with: m.range(at: 1)).lowercased()
        if !allowedFixtureHosts.contains(host) { count += 1 }
    }
    count += ipv4Regex.numberOfMatches(in: text, range: whole)
    return count
}
