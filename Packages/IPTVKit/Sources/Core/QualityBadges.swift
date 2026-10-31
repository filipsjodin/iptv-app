import Foundation

/// Ett kvalitetsmärke på en titel (upplösning, HDR-format eller ljud).
public enum QualityBadge: String, Sendable, CaseIterable {
    case uhd4K = "4K"
    case dolbyVision = "Dolby Vision"
    case hdr = "HDR"
    case atmos = "Atmos"
    case surround51 = "5.1"
}

/// Tolkar kvalitetstaggar ur leverantörens titel (t.ex. "Film 2160p HDR10 Atmos 5.1").
public enum QualityBadges {
    /// Märkena som titeln anger, ordnade enligt `QualityBadge.allCases` och utan dubbletter. Taggar matchas som hela
    /// ord (skiftlägesokänsligt): `DV` matchar inte i `DVD`, `HDR` inte i `HDRip`.
    ///
    /// `containerExtension` (t.ex. "mkv") säger inget om kvaliteten och påverkar inte resultatet, men parametern
    /// finns kvar så att anroparna inte behöver ändras om en container senare får betydelse.
    public static func parse(title: String, containerExtension: String?) -> [QualityBadge] {
        _ = containerExtension
        let lowered = title.lowercased()
        // Ord = obrutna följder av bokstäver och siffror; allt annat (mellanslag, punkt, bindestreck, `+`) skiljer.
        let words = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let wordSet = Set(words)
        var found: Set<QualityBadge> = []
        if !wordSet.isDisjoint(with: ["4k", "uhd", "2160p"]) { found.insert(.uhd4K) }
        if !wordSet.isDisjoint(with: ["dv", "dovi"]) || containsSequence(words, ["dolby", "vision"]) {
            found.insert(.dolbyVision)
        }
        if !wordSet.isDisjoint(with: ["hdr", "hdr10"]) { found.insert(.hdr) }
        if wordSet.contains("atmos") { found.insert(.atmos) }
        if containsSurround51(lowered) { found.insert(.surround51) }
        return QualityBadge.allCases.filter(found.contains)
    }

    private static func containsSequence(_ words: [String], _ sequence: [String]) -> Bool {
        guard words.count >= sequence.count else { return false }
        for start in 0...(words.count - sequence.count) where Array(words[start..<(start + sequence.count)]) == sequence {
            return true
        }
        return false
    }

    /// "5.1" som eget ord: ingen bokstav eller siffra direkt före, och ingen siffra efter (så inte "15.1", "5.10"
    /// eller "5.1.2").
    private static func containsSurround51(_ lowered: String) -> Bool {
        let chars = Array(lowered)
        guard chars.count >= 3 else { return false }
        for i in 0...(chars.count - 3) where chars[i] == "5" && chars[i + 1] == "." && chars[i + 2] == "1" {
            if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { continue }
            if i + 3 < chars.count {
                let next = chars[i + 3]
                if next.isLetter || next.isNumber { continue }
                if next == ".", i + 4 < chars.count, chars[i + 4].isNumber { continue }
            }
            return true
        }
        return false
    }
}
