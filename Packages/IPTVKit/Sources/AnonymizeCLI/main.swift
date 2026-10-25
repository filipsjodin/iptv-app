import Foundation
import Core
import Providers
import AnonymizeKit
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

let unreachableMessage = "Servern svarar inte (timeout). Testa i webbläsare/IPTV-app på samma nät."

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

// MARK: - Skrivning

let leakMessage = "Läckagevakten hittade misstänkta värden i utdata. Inget skrevs."
let shortCredentialWarning = "Varning: en inloggningsuppgift är kortare än 4 tecken, redigeringen kan förvanska utdata."

func writeOutputs(catalog: ProviderCatalog, summary: String, to outDir: URL, output: Output) throws {
    var files = try renderFixtures(catalog).map { (name: "fixtures/" + $0.name, text: output.clean($0.text)) }
    files.append((name: "summary.md", text: output.clean(summary)))
    guard files.reduce(0, { $0 + fixtureLeaks(in: $1.text) }) == 0 else {
        throw CLIFailure(code: 1, message: leakMessage)
    }
    try FileManager.default.createDirectory(at: outDir.appendingPathComponent("fixtures", isDirectory: true),
                                            withIntermediateDirectories: true)
    for f in files { try Data(f.text.utf8).write(to: outDir.appendingPathComponent(f.name)) }
}

// MARK: - Huvudflöde

func run() async -> Int32 {
    var output = Output(secret: nil)
    do {
        let args = try parseArguments(Array(CommandLine.arguments.dropFirst()))
        guard let raw = try? String(contentsOfFile: args.source, encoding: .utf8) else {
            throw CLIFailure(code: 66, message: "Kunde inte läsa källfilen.")
        }
        let secret = try parseSource(raw)
        output.secret = secret
        if hasShortCredentials(secret) { Output(secret: nil).err(shortCredentialWarning) }

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
