import Foundation

public struct CleanTitle: Sendable, Equatable {
    public var title: String
    public var year: Int?
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

        // Landsprefix; "IT: ..." är en riktig titel, inte ett språk.
        if let split = NameScanner.splitCountryPrefix(text), split.code != "IT" {
            text = split.rest
        }

        // Taggar i hakparenteser/parenteser. `(YYYY)` ger årtal, övriga tas bort.
        var year: Int?
        var out = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == "[" {
                let close: Character = c == "(" ? ")" : "]"
                if let end = chars[(i + 1)...].firstIndex(of: close) {
                    let inner = NameScanner.trim(String(chars[(i + 1)..<end]))
                    if year == nil, let y = isYear(inner) { year = y }
                    out.append(" ")
                    i = end + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        var title = NameScanner.trim(out)

        // Avslutande kvalitetstaggar (en i taget).
        while let split = NameScanner.splitLastToken(title), qualityTokens.contains(split.token.uppercased()) {
            title = split.rest
        }

        // Fritt årtal sist i titeln, men aldrig om det är hela titeln.
        if year == nil, let split = NameScanner.splitLastToken(title), let y = isYear(split.token) {
            year = y
            title = split.rest
            if let dash = NameScanner.splitLastToken(title), dash.token == "-" { title = dash.rest }
        }

        if title.isEmpty { return CleanTitle(title: original, year: nil) }
        return CleanTitle(title: title, year: year)
    }

    private static let qualityTokens: Set<String> = [
        "4K", "UHD", "FHD", "HD", "SD", "HDR", "HDR10", "HEVC", "H264", "H265", "X264", "X265",
        "2160P", "1080P", "720P", "480P",
    ]
}
