import Foundation
import Core

public struct ChannelGroup: Sendable, Identifiable {
    /// Hela grupperingsnyckeln (land + groupKey + categoryID), unik över länder och kategorier.
    public let id: String
    public let displayName: String
    public let logoURL: URL?
    /// Bäst först (kvalitet fallande, HDR före SDR, därefter providerID).
    public let variants: [LiveStream]

    private let traits: [NormalizedChannelName]

    /// Skiljetecken i grupp-id:t och markören före providerID för en manuellt uppdelad variant. Id-formatet
    /// definieras här och i `ChannelGrouper.group(_:splitProviderIDs:)`, ingen annanstans.
    fileprivate static let separator = "\u{1F}"
    fileprivate static let splitMarker = separator + "split" + separator

    /// Sant när gruppen är en manuellt uppdelad variant (id byggt av `ChannelGrouper.group(_:splitProviderIDs:)`).
    public var isManualSplit: Bool { id.contains(Self.splitMarker) }

    public func preferred(displaySupportsHDR: Bool) -> LiveStream {
        var best = 0
        for i in variants.indices.dropFirst() {
            let a = traits[i], b = traits[best]
            let better: Bool
            if !displaySupportsHDR, a.isHDR != b.isHDR { better = !a.isHDR }
            else if a.quality != b.quality { better = a.quality > b.quality }
            else if a.isHDR != b.isHDR { better = a.isHDR }
            else { better = variants[i].providerID < variants[best].providerID }
            if better { best = i }
        }
        return variants[best]
    }

    init(id: String, displayName: String, logoURL: URL?, variants: [LiveStream], traits: [NormalizedChannelName]) {
        self.id = id
        self.displayName = displayName
        self.logoURL = logoURL
        self.variants = variants
        self.traits = traits
    }
}

public enum ChannelGrouper {
    public static func group(_ streams: [LiveStream]) -> [ChannelGroup] {
        group(streams, splitProviderIDs: [])
    }

    /// Som `group(_:)`, men varje stream vars `providerID` finns i `splitProviderIDs` får en egen grupp
    /// (id `<ursprungligt id>\u{1F}split\u{1F}<providerID>`); övriga varianter hålls ihop.
    public static func group(_ streams: [LiveStream], splitProviderIDs: Set<String>) -> [ChannelGroup] {
        struct Entry { var stream: LiveStream; var name: NormalizedChannelName }
        var order: [String] = []
        var buckets: [String: [Entry]] = [:]

        for stream in streams {
            let n = ChannelNameNormalizer.normalize(stream.name)
            var key = [n.country ?? "", n.groupKey, stream.categoryID ?? ""].joined(separator: ChannelGroup.separator)
            if splitProviderIDs.contains(stream.providerID) { key += ChannelGroup.splitMarker + stream.providerID }
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
                                variants: sorted.map(\.stream),
                                traits: sorted.map(\.name))
        }
    }
}
