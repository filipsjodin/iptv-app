import Foundation
import Core

public struct FormatSummary: Sendable, Codable, Equatable {
    public var containersByKind: [ContentKind: [String: Int]]
    public var totals: [ContentKind: Int]

    public init(containersByKind: [ContentKind: [String: Int]], totals: [ContentKind: Int]) {
        self.containersByKind = containersByKind
        self.totals = totals
    }
}

public enum PlaylistStats {
    /// Antal per container och typ. Serier räknas via sina avsnitt; `totals[.series]` är antalet serier.
    public static func summarize(_ catalog: ProviderCatalog) -> FormatSummary {
        var containers: [ContentKind: [String: Int]] = [:]
        func count(_ kind: ContentKind, _ declared: String?, _ locator: StreamLocator) {
            let key = normalized(declared) ?? container(of: locator) ?? "unknown"
            containers[kind, default: [:]][key, default: 0] += 1
        }
        for m in catalog.movies { count(.movie, m.container, m.locator) }
        for e in catalog.episodes { count(.series, e.container, e.locator) }
        for l in catalog.live { count(.live, nil, l.locator) }
        return FormatSummary(containersByKind: containers, totals: [
            .movie: catalog.movies.count, .series: catalog.series.count, .live: catalog.live.count,
        ])
    }

    private static func normalized(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        return s
    }

    private static func container(of locator: StreamLocator) -> String? {
        switch locator {
        case let .xtream(_, _, container): return normalized(container)
        case let .template(t):
            let path = t.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? t
            guard let last = path.split(separator: "/").last, let dot = last.lastIndex(of: ".") else { return nil }
            let ext = String(last[last.index(after: dot)...])
            return ext.isEmpty || ext.contains("{") ? nil : normalized(ext)
        }
    }
}
