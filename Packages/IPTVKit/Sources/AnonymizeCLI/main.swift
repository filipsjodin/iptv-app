import Foundation
import Core
import Providers
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// iptv-anonymize --source <fil> --out <katalog>
// All utdata (stdout, stderr, filer) passerar Redactor. Utan känd secret skrivs bara fasta meddelanden.

struct Output {
    var secret: PlaylistSecret?

    func clean(_ s: String) -> String {
        secret.map { Redactor.redact(s, secret: $0) } ?? s
    }
    func out(_ s: String) { FileHandle.standardOutput.write(Data((clean(s) + "\n").utf8)) }
    func err(_ s: String) { FileHandle.standardError.write(Data((clean(s) + "\n").utf8)) }
}

struct CLIFailure: Error {
    let code: Int32
    let message: String
}

let unreachableMessage = "Servern svarar inte (timeout). Testa i webbläsare/IPTV-app på samma nät."
let placeholderHost = "example.invalid"
let maxFixtureItems = 300

// MARK: - Argument och källa

func parseArguments(_ args: [String]) throws -> (source: String, out: String) {
    var source: String?
    var out: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--source" where i + 1 < args.count: source = args[i + 1]; i += 2
        case "--out" where i + 1 < args.count: out = args[i + 1]; i += 2
        default: throw CLIFailure(code: 64, message: "Användning: iptv-anonymize --source <fil> --out <katalog>")
        }
    }
    guard let source, let out else {
        throw CLIFailure(code: 64, message: "Användning: iptv-anonymize --source <fil> --out <katalog>")
    }
    return (source, out)
}

/// Källfilen ska ha exakt en icke-tom rad. Felmeddelanden nämner aldrig innehållet.
func parseSource(_ text: String) throws -> PlaylistSecret {
    let lines = text.split(whereSeparator: \.isNewline)
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
    let last = c.path.split(separator: "/").last.map(String.init) ?? ""
    let isXtreamPath = ["player_api.php", "get.php", "xmltv.php"].contains(last.lowercased())
    let isBareServer = last.isEmpty

    if isXtreamPath || (isBareServer && user != nil && pass != nil) {
        guard let user, let pass, !user.isEmpty, !pass.isEmpty else {
            throw CLIFailure(code: 65, message: "Xtream-URL:en saknar username och/eller password.")
        }
        var server = URLComponents()
        server.scheme = scheme
        server.host = host
        server.port = c.port
        guard let serverURL = server.url else { throw CLIFailure(code: 65, message: "Ogiltig serveradress.") }
        return .xtream(server: serverURL, username: user, password: pass)
    }
    return .m3u(url: url, epgURL: nil)
}

// MARK: - Hämtning

func fetchCatalog(secret: PlaylistSecret) async throws -> (ProviderCatalog, XtreamAccount?) {
    let http = URLSessionHTTPClient(timeout: 30)
    switch secret {
    case let .xtream(server, username, password):
        let client = XtreamClient(server: server, username: username, password: password, http: http)
        let account = try await client.account()
        var catalog = try await client.catalog()
        // Några serier räcker för att se avsnittscontainrar utan att belasta servern.
        for s in catalog.series.prefix(5) {
            if let eps = try? await client.episodes(seriesID: s.providerID) { catalog.episodes += eps }
        }
        return (catalog, account)
    case let .m3u(url, _):
        let (data, status) = try await http.get(url)
        guard (200..<300).contains(status) else { throw ProviderError.http(status) }
        let playlist = M3UParser.parse(String(decoding: data, as: UTF8.self))
        return (M3UMapper.catalog(from: playlist, secret: secret), nil)
    }
}

// MARK: - Sammanfattning

func percent(_ n: Int, of total: Int) -> String {
    guard total > 0 else { return "0.0" }
    let tenths = (n * 1000 + total / 2) / total
    return "\(tenths / 10).\(tenths % 10)"
}

let kindOrder: [(ContentKind, String)] = [(.movie, "Filmer"), (.series, "Serier"), (.live, "Live")]

func buildSummary(catalog: ProviderCatalog, account: XtreamAccount?) -> String {
    let stats = PlaylistStats.summarize(catalog)
    var md = ["# Spellistesammanfattning", ""]

    md += ["## Konto", ""]
    if let a = account {
        md += ["- Status: \(a.status)",
               "- Utgår: \(a.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "okänt")",
               "- Max anslutningar: \(a.maxConnections)",
               "- Tillåtna format: \(a.allowedOutputFormats.joined(separator: ", "))"]
    } else {
        md += ["- Ingen kontoinfo (M3U-källa)"]
    }

    md += ["", "## Antal per typ", ""]
    for (kind, label) in kindOrder { md.append("- \(label): \(stats.totals[kind] ?? 0)") }
    md.append("- Avsnitt (hämtade): \(catalog.episodes.count)")

    md += ["", "## Containrar per typ", ""]
    for (kind, label) in kindOrder {
        let counts = stats.containersByKind[kind] ?? [:]
        let total = counts.values.reduce(0, +)
        let line = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) \(percent($0.value, of: total)) %" }.joined(separator: ", ")
        md.append("- \(label): \(line.isEmpty ? "-" : line)")
    }

    md += ["", "## Vanligaste kategorier (30 per typ)"]
    let categoryNames = Dictionary(catalog.categories.map { ("\($0.kind.rawValue)|\($0.providerID)", $0.name) },
                                   uniquingKeysWith: { a, _ in a })
    let categoryIDs: [ContentKind: [String?]] = [
        .movie: catalog.movies.map(\.categoryID),
        .series: catalog.series.map(\.categoryID),
        .live: catalog.live.map(\.categoryID),
    ]
    for (kind, label) in kindOrder {
        var counts: [String: Int] = [:]
        for id in categoryIDs[kind] ?? [] {
            guard let id else { continue }
            counts[categoryNames["\(kind.rawValue)|\(id)"] ?? id, default: 0] += 1
        }
        md += ["", "### \(label)", ""]
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(30)
        md += top.isEmpty ? ["-"] : top.map { "- \($0.key) (\($0.value))" }
    }

    md += ["", "## Slumpade råa namn (50 per typ)"]
    let names: [ContentKind: [String]] = [
        .movie: catalog.movies.map(\.title), .series: catalog.series.map(\.title), .live: catalog.live.map(\.name),
    ]
    for (kind, label) in kindOrder {
        md += ["", "### \(label)", ""]
        let sample = (names[kind] ?? []).shuffled().prefix(50)
        md += sample.isEmpty ? ["-"] : sample.map { "- \($0.replacingOccurrences(of: "\n", with: " "))" }
    }

    md += ["", "## Live-gruppering", ""]
    let groups = ChannelGrouper.group(catalog.live)
    let grouped = groups.filter { $0.variants.count > 1 }.reduce(0) { $0 + $1.variants.count }
    md.append("- Kanaler: \(catalog.live.count), grupper: \(groups.count)")
    md.append("- Kanaler som grupperades med minst en variant: \(grouped) (\(percent(grouped, of: catalog.live.count)) %)")
    return md.joined(separator: "\n") + "\n"
}

// MARK: - Fixtures

func anonymizedAsset(_ url: URL?) -> URL? {
    guard let url else { return nil }
    let name = url.lastPathComponent.isEmpty ? "x" : url.lastPathComponent
    return URL(string: "https://\(placeholderHost)/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "x"))
}

func fixtureCatalog(_ c: ProviderCatalog) -> ProviderCatalog {
    var movies = Array(c.movies.prefix(maxFixtureItems))
    var series = Array(c.series.prefix(maxFixtureItems))
    var live = Array(c.live.prefix(maxFixtureItems))
    for i in movies.indices { movies[i].posterURL = anonymizedAsset(movies[i].posterURL) }
    for i in series.indices { series[i].posterURL = anonymizedAsset(series[i].posterURL) }
    for i in live.indices { live[i].logoURL = anonymizedAsset(live[i].logoURL) }
    return ProviderCatalog(categories: c.categories, movies: movies, series: series,
                           episodes: Array(c.episodes.prefix(maxFixtureItems)), live: live)
}

/// Direktlänk med platshållarinloggning, host `example.invalid` och utan query/fragment.
func placeholderURL(_ locator: StreamLocator) -> String {
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

func sampleM3U(_ c: ProviderCatalog) -> String {
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

func writeFile(_ text: String, to url: URL, output: Output) throws {
    try Data(output.clean(text).utf8).write(to: url)
}

func writeOutputs(catalog: ProviderCatalog, summary: String, to outDir: URL, output: Output) throws {
    let fixturesDir = outDir.appendingPathComponent("fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
    try writeFile(summary, to: outDir.appendingPathComponent("summary.md"), output: output)

    let fx = fixtureCatalog(catalog)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    func json<T: Encodable>(_ value: T, _ name: String) throws {
        let data = try encoder.encode(value)
        try writeFile(String(decoding: data, as: UTF8.self), to: fixturesDir.appendingPathComponent(name), output: output)
    }
    try json(fx.categories, "categories.json")
    try json(fx.movies, "movies.json")
    try json(fx.series, "series.json")
    try json(fx.episodes, "episodes.json")
    try json(fx.live, "live.json")
    try writeFile(sampleM3U(fx), to: fixturesDir.appendingPathComponent("sample.m3u"), output: output)
}

// MARK: - Huvudflöde

func isUnreachable(_ error: Error) -> Bool {
    if let p = error as? ProviderError, p == .unreachable { return true }
    guard let u = error as? URLError else { return false }
    return [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
            .notConnectedToInternet, .dnsLookupFailed].contains(u.code)
}

func run() async -> Int32 {
    var output = Output(secret: nil)
    do {
        let args = try parseArguments(Array(CommandLine.arguments.dropFirst()))
        guard let raw = try? String(contentsOfFile: args.source, encoding: .utf8) else {
            throw CLIFailure(code: 66, message: "Kunde inte läsa källfilen.")
        }
        let secret = try parseSource(raw)
        output.secret = secret

        let catalog: ProviderCatalog
        let account: XtreamAccount?
        do {
            (catalog, account) = try await fetchCatalog(secret: secret)
        } catch {
            if isUnreachable(error) { throw CLIFailure(code: 2, message: unreachableMessage) }
            throw CLIFailure(code: 1, message: "Hämtningen misslyckades: \(error)")
        }

        let outDir = URL(fileURLWithPath: args.out, isDirectory: true)
        try writeOutputs(catalog: catalog, summary: buildSummary(catalog: catalog, account: account),
                         to: outDir, output: output)
        let stats = PlaylistStats.summarize(catalog)
        output.out("Klart. Filmer: \(stats.totals[.movie] ?? 0), serier: \(stats.totals[.series] ?? 0), live: \(stats.totals[.live] ?? 0).")
        output.out("Skrev summary.md och fixtures/ i \(args.out)")
        return 0
    } catch let f as CLIFailure {
        output.err(f.message)
        return f.code
    } catch {
        output.err("Fel: \(error)")
        return 1
    }
}

exit(await run())
