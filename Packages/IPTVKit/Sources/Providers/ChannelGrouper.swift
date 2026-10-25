import Foundation
import Core

public struct ChannelGroup: Sendable, Identifiable {
    /// Hela grupperingsnyckeln (land + groupKey + categoryID), unik över länder och kategorier.
    public let id: String
    public let displayName: String
    public let logoURL: URL?
    /// Bäst först (kvalitet fallande, HDR före SDR, därefter providerID).
    public let variants: [LiveStream]

    public func preferred(displaySupportsHDR: Bool) -> LiveStream {
        let ranked = variants.map { ($0, ChannelNameNormalizer.normalize($0.name)) }
        let best = ranked.min { a, b in
            if !displaySupportsHDR, a.1.isHDR != b.1.isHDR { return !a.1.isHDR }
            if a.1.quality != b.1.quality { return a.1.quality > b.1.quality }
            if a.1.isHDR != b.1.isHDR { return a.1.isHDR }
            return a.0.providerID < b.0.providerID
        }
        return best?.0 ?? variants[0]
    }

    init(id: String, displayName: String, logoURL: URL?, variants: [LiveStream]) {
        self.id = id
        self.displayName = displayName
        self.logoURL = logoURL
        self.variants = variants
    }
}

public enum ChannelGrouper {
    public static func group(_ streams: [LiveStream]) -> [ChannelGroup] {
        struct Entry { var stream: LiveStream; var name: NormalizedChannelName }
        var order: [String] = []
        var buckets: [String: [Entry]] = [:]

        for stream in streams {
            let n = ChannelNameNormalizer.normalize(stream.name)
            let key = [n.country ?? "", n.groupKey, stream.categoryID ?? ""].joined(separator: "\u{1F}")
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(Entry(stream: stream, name: n))
        }

        return order.map { key in
            let sorted = buckets[key]!.sorted { a, b in
                if a.name.quality != b.name.quality { return a.name.quality > b.name.quality }
                if a.name.isHDR != b.name.isHDR { return a.name.isHDR }
                return a.stream.providerID < b.stream.providerID
            }
            return ChannelGroup(id: key,
                                displayName: sorted[0].name.baseName,
                                logoURL: sorted.lazy.compactMap(\.stream.logoURL).first,
                                variants: sorted.map(\.stream))
        }
    }
}
