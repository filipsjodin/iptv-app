import Foundation

public enum VideoQuality: Int, Comparable, Sendable, Codable {
    case unknown = 0, sd, hd, fhd, uhd

    public static func < (lhs: VideoQuality, rhs: VideoQuality) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct NormalizedChannelName: Sendable, Equatable {
    public var baseName: String
    public var groupKey: String
    public var country: String?
    public var quality: VideoQuality
    public var isHDR: Bool
    public var isHighFrameRate: Bool
}

public enum ChannelNameNormalizer {
    public static func normalize(_ raw: String) -> NormalizedChannelName {
        // Rubriker/avskiljare (`##### SVERIGE #####`) lämnas orörda.
        if NameScanner.isSeparatorOrHeader(raw) {
            return NormalizedChannelName(baseName: raw, groupKey: groupKey(for: raw), country: nil,
                                         quality: .unknown, isHDR: false, isHighFrameRate: false)
        }

        var name = NameScanner.trim(raw)
        var country: String?
        if let split = NameScanner.splitCountryPrefix(name) {
            country = split.code
            name = split.rest
        }

        var quality = VideoQuality.unknown
        var isHDR = false
        var isHFR = false
        var strippedAny = false

        func apply(_ tag: Tag) {
            if let q = tag.quality { quality = max(quality, q) }
            isHDR = isHDR || tag.hdr
            isHFR = isHFR || tag.hfr
            strippedAny = true
        }

        while true {
            let t = NameScanner.trim(name)
            let (rest, token) = NameScanner.splitLastToken(t) ?? ("", t)
            if qualityTags[NameScanner.unwrap(token)] == nil, let glued = gluedTag(token) {
                apply(glued.tag)
                name = rest.isEmpty ? glued.base : rest + " " + glued.base
                continue
            }
            guard !rest.isEmpty else { name = t; break }
            let unwrapped = NameScanner.unwrap(token)
            if let tag = lookup(unwrapped, wrapped: unwrapped != token) {
                apply(tag)
                name = rest
            } else if strippedAny, token == "-" || token == "|" {
                name = rest
            } else {
                name = t
                break
            }
        }

        return NormalizedChannelName(baseName: name, groupKey: groupKey(for: name), country: country,
                                     quality: quality, isHDR: isHDR, isHighFrameRate: isHFR)
    }

    /// Gemener (språkoberoende), diakritiska tecken behålls, blanksteg kollapsade.
    static func groupKey(for name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `RAW` räknas bara som tagg i exakt versaler eller inom hakparenteser ("WWE Raw" ska inte slås ihop med "WWE").
    private static func lookup(_ token: String, wrapped: Bool) -> Tag? {
        if let tag = qualityTags[token] { return tag }
        let upper = token.uppercased()
        if upper == "RAW", !wrapped { return nil }
        return qualityTags[upper]
    }

    /// Superscript-taggar som sitter ihop med namnet ("TV4ᴴᴰ").
    private static func gluedTag(_ token: String) -> (base: String, tag: Tag)? {
        for suffix in ["ᶠᴴᴰ", "ᵁᴴᴰ", "ᴴᴰ"] where token.count > suffix.count && token.hasSuffix(suffix) {
            guard let tag = qualityTags[suffix] else { continue }
            return (String(token.dropLast(suffix.count)), tag)
        }
        return nil
    }

    private struct Tag {
        var quality: VideoQuality?
        var hdr = false
        var hfr = false
    }

    private static let qualityTags: [String: Tag] = [
        "SD": Tag(quality: .sd),
        "HD": Tag(quality: .hd), "ᴴᴰ": Tag(quality: .hd),
        "FHD": Tag(quality: .fhd), "ᶠᴴᴰ": Tag(quality: .fhd),
        "UHD": Tag(quality: .uhd), "ᵁᴴᴰ": Tag(quality: .uhd), "4K": Tag(quality: .uhd),
        "HDR": Tag(hdr: true), "HDR10": Tag(hdr: true),
        "HEVC": Tag(), "H264": Tag(), "H265": Tag(), "RAW": Tag(),
        "50FPS": Tag(hfr: true), "60FPS": Tag(hfr: true),
    ]
}

/// Teckennivåskanning (Character, inte unicode scalars) så att grafem-kluster som `⚽️` aldrig delas.
enum NameScanner {
    static func trim(_ s: String) -> String {
        var sub = Substring(s)
        while let f = sub.first, f.isWhitespace { sub.removeFirst() }
        while let l = sub.last, l.isWhitespace { sub.removeLast() }
        return String(sub)
    }

    /// Delar av sista blankstegsseparerade token. `nil` om det bara finns en token (hela namnet) eller resten är tom.
    static func splitLastToken(_ s: String) -> (rest: String, token: String)? {
        let t = trim(s)
        guard let idx = t.lastIndex(where: \.isWhitespace) else { return nil }
        let token = String(t[t.index(after: idx)...])
        let rest = trim(String(t[..<idx]))
        guard !rest.isEmpty, !token.isEmpty else { return nil }
        return (rest, token)
    }

    /// Tar bort omslutande `[]` eller `()` runt en token.
    static func unwrap(_ token: String) -> String {
        guard token.count > 2, let f = token.first, let l = token.last else { return token }
        if (f == "[" && l == "]") || (f == "(" && l == ")") { return String(token.dropFirst().dropLast()) }
        return token
    }

    static func isSeparatorOrHeader(_ raw: String) -> Bool {
        let t = trim(raw)
        guard let first = t.first else { return false }
        if !t.contains(where: { $0.isLetter || $0.isNumber }) { return true }
        if !first.isLetter, !first.isNumber, !first.isWhitespace {
            var run = 0
            for c in t { if c == first { run += 1 } else { break } }
            if run >= 3 { return true }
        }
        return false
    }

    private static func isUpperASCII(_ c: Character) -> Bool {
        guard c.isASCII, let a = c.asciiValue else { return false }
        return a >= 65 && a <= 90
    }

    /// Landsprefix: `SE: `, `|SE| `, `[SE] `, `SE | `, `SE - `. Koden måste finnas i `CountryCodes`.
    /// Med `allowColon: false` (titlar) godtas inte formen `XX:`.
    static func splitCountryPrefix(_ s: String, allowColon: Bool = true) -> (code: String, rest: String)? {
        let chars = Array(s)
        var i = 0
        var opener: Character?
        if i < chars.count, chars[i] == "|" || chars[i] == "[" { opener = chars[i]; i += 1 }
        let start = i
        while i < chars.count, i - start < 6, isUpperASCII(chars[i]) { i += 1 }
        guard i - start >= 2 else { return nil }
        if i < chars.count, chars[i].isLetter || chars[i].isNumber { return nil }
        let code = String(chars[start..<i])
        guard CountryCodes.contains(code) else { return nil }

        var j = i
        func sepAt(_ k: Int) -> Bool {
            guard k < chars.count else { return false }
            switch chars[k] {
            case ":": return allowColon
            case "|": return true
            case "-": return k + 1 < chars.count && chars[k + 1].isWhitespace
            default: return false
            }
        }

        if let opener {
            let closer: Character = opener == "[" ? "]" : "|"
            guard j < chars.count, chars[j] == closer else { return nil }
            j += 1
            var k = j
            while k < chars.count, chars[k].isWhitespace { k += 1 }
            if sepAt(k) { j = k + 1 }
        } else {
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard sepAt(j) else { return nil }
            j += 1
        }
        let rest = trim(String(chars[j...]))
        guard !rest.isEmpty else { return nil }
        return (code, rest)
    }
}
