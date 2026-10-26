import Foundation

public enum LanguageCode {
    /// ISO 639-1/-2 (B och T) samt engelska namn -> ISO 639-1 (norska varianter -> "no").
    private static let table: [String: String] = {
        let groups: [(String, [String])] = [
            ("sv", ["sv", "swe", "sve", "swedish", "svenska"]),
            ("en", ["en", "eng", "english"]),
            ("no", ["no", "nb", "nn", "nor", "nob", "nno", "norwegian", "bokmal", "nynorsk"]),
            ("da", ["da", "dan", "danish"]),
            ("fi", ["fi", "fin", "finnish"]),
            ("de", ["de", "deu", "ger", "german"]),
            ("fr", ["fr", "fra", "fre", "french"]),
            ("es", ["es", "spa", "spanish"]),
            ("it", ["it", "ita", "italian"]),
            ("ar", ["ar", "ara", "arabic"]),
            ("tr", ["tr", "tur", "turkish"]),
            ("pl", ["pl", "pol", "polish"]),
            ("nl", ["nl", "nld", "dut", "dutch"]),
            ("pt", ["pt", "por", "portuguese"]),
        ]
        var t: [String: String] = [:]
        for (code, names) in groups { for n in names { t[n] = code } }
        return t
    }()

    /// Normaliserar en språkkod eller ett språknamn till ISO 639-1 där det är känt.
    /// Okänt -> primär subtag i gemener om den är 2-3 bokstäver, annars nil.
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return nil }
        if let hit = table[lower] { return hit }
        let primary = String(lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        if let hit = table[primary] { return hit }
        let isLetters = primary.unicodeScalars.allSatisfy { $0.value >= 97 && $0.value <= 122 }
        return (primary.count == 2 || primary.count == 3) && isLetters ? primary : nil
    }
}
