import Foundation
import Core

public enum EPGMatcher {
    /// groupID → XMLTV-kanal-id. Först `epgChannelID` hos någon variant (bästa först) som finns bland XMLTV-kanalerna, sedan normaliserat namn
    /// mot XMLTV-kanalernas `names`. Grupper utan träff saknas i resultatet.
    public static func match(groups: [ChannelGroup], xmltvChannels: [EPGChannel]) -> [String: String] {
        // Namnindex byggs en gång; vid dubletter vinner första.
        var index: [String: String] = [:]
        for channel in xmltvChannels {
            for name in channel.names {
                let key = nameKey(name)
                if !key.isEmpty, index[key] == nil { index[key] = channel.id }
            }
        }

        let knownIDs = Set(xmltvChannels.map(\.id))
        var result: [String: String] = [:]
        for group in groups {
            if let id = group.variants.lazy.compactMap(\.epgChannelID).first(where: knownIDs.contains) {
                result[group.id] = id
            } else if let id = index[nameKey(group.displayName)] {
                result[group.id] = id
            }
        }
        return result
    }

    /// Samma normalisering som grupperingen, men utan blanksteg så att "SVT1" och "SVT 1" möts.
    private static func nameKey(_ name: String) -> String {
        String(ChannelNameNormalizer.normalize(name).groupKey.filter { !$0.isWhitespace })
    }
}
