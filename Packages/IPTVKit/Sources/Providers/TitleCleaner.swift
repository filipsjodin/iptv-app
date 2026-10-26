import Foundation

public struct CleanTitle: Sendable, Equatable {
    public var title: String
    public var year: Int?

    public init(title: String, year: Int?) {
        self.title = title
        self.year = year
    }
}

public enum TitleCleaner {
    public static func clean(_ raw: String) -> CleanTitle { clean(raw, now: Date()) }

    static func clean(_ raw: String, now: Date) -> CleanTitle {
        let maxYear = Calendar(identifier: .gregorian).component(.year, from: now) + 1
        func isYear(_ s: String) -> Int? {
            guard s.count == 4, s.allSatisfy({ $0.isASCII && $0.isNumber }), let y = Int(s),
                  (1900...maxYear).contains(y) else { return nil }
            return y
        }

        let original = NameScanner.trim(raw)
        var text = original

        // Landsprefix (aldrig formen `XX:`, den förekommer i riktiga titlar som "CSI: Miami").
        if let split = NameScanner.splitCountryPrefix(text, allowColon: false) { text = split.rest }

        // `(YYYY)` / `[YYYY]` var som helst: ger årtal (längst till höger vinner) och tas bort.
        var year: Int?
        text = removeGroups(in: text) { inner in
            guard let y = isYear(inner) else { return false }
            year = y
            return true
        }

        // Inledande grupper tas bara bort om de är taggliknande, och bara om titeltext följer.
        while let g = leadingGroup(in: text), isTagLike(g.inner), !g.rest.isEmpty { text = g.rest }

        // Avslutande grupper, kvalitetstaggar, separatorer och (villkorligt) fritt årtal.
        var title = NameScanner.trim(text)
        var sawTag = false
        while true {
            title = NameScanner.trim(title)
            if let g = trailingGroup(in: title), !g.rest.isEmpty {
                title = g.rest
                sawTag = true
                continue
            }
            guard let split = NameScanner.splitLastToken(title) else { break }
            let token = split.token
            if qualityTokens.contains(token.uppercased()) {
                title = split.rest
                sawTag = true
            } else if token == "-" || token == "|" || token == ":" {
                title = split.rest
            } else if year == nil, let y = isYear(token) {
                // Ett bart årtal räknas bara om taggar följer, eller om en uttrycklig separator står före.
                if sawTag {
                    year = y
                    title = split.rest
                } else if let sep = NameScanner.splitLastToken(split.rest), [".", "-", "|"].contains(sep.token) {
                    year = y
                    title = sep.rest
                } else {
                    break
                }
            } else {
                break
            }
        }

        // Kollapsa blanksteg och trimma avslutande separatorer.
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = title.last, last == "-" || last == "|" || last == ":", title.count > 1 {
            title.removeLast()
            title = NameScanner.trim(title)
        }

        if title.isEmpty { return CleanTitle(title: original, year: nil) }
        return CleanTitle(title: title, year: year)
    }

    // MARK: - Gruppverktyg

    private static let tagLikeContents: Set<String> = [
        "MULTI", "MULTI-SUB", "MULTISUB", "SUB", "SUBS", "DUAL", "VOSTFR", "4K", "UHD", "FHD", "HD", "HDR",
        "HDR10", "DOLBY VISION", "DV", "ATMOS", "3D", "HEVC",
    ]

    private static func isTagLike(_ inner: String) -> Bool {
        let upper = NameScanner.trim(inner).uppercased()
        return tagLikeContents.contains(upper) || CountryCodes.contains(upper)
    }

    private static func closer(for opener: Character) -> Character? {
        switch opener {
        case "(": ")"
        case "[": "]"
        default: nil
        }
    }

    /// Tar bort grupper (`(..)`/`[..]`) var som helst där `predicate` är sann för innehållet.
    private static func removeGroups(in text: String, where predicate: (String) -> Bool) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if let close = closer(for: chars[i]), let end = chars[(i + 1)...].firstIndex(of: close),
               predicate(NameScanner.trim(String(chars[(i + 1)..<end]))) {
                out.append(" ")
                i = end + 1
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func leadingGroup(in text: String) -> (inner: String, rest: String)? {
        let t = NameScanner.trim(text)
        let chars = Array(t)
        guard let first = chars.first, let close = closer(for: first),
              let end = chars.firstIndex(of: close) else { return nil }
        return (String(chars[1..<end]), NameScanner.trim(String(chars[(end + 1)...])))
    }

    private static func trailingGroup(in text: String) -> (inner: String, rest: String)? {
        let chars = Array(NameScanner.trim(text))
        guard let last = chars.last, last == ")" || last == "]" else { return nil }
        let opener: Character = last == ")" ? "(" : "["
        guard let start = chars.dropLast().lastIndex(of: opener) else { return nil }
        return (String(chars[(start + 1)..<(chars.count - 1)]), NameScanner.trim(String(chars[..<start])))
    }

    private static let qualityTokens: Set<String> = [
        "4K", "UHD", "FHD", "HD", "SD", "HDR", "HDR10", "HEVC", "H264", "H265", "X264", "X265",
        "2160P", "1080P", "720P", "480P",
    ]
}
