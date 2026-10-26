import Foundation

/// Mappar TMDB-certifieringar (åldersgränser) till en ålder.
public enum Certification {
    /// Högsta ålder som räknas som barnvänligt innehåll.
    public static let kidsMaxAge = 11

    private static let tables: [String: [String: Int]] = [
        "SE": ["BTL": 0, "7": 7, "11": 11, "15": 15],
        "US": [
            "G": 0, "PG": 7, "PG-13": 13, "R": 17, "NC-17": 18,
            "TV-Y": 0, "TV-G": 0, "TV-Y7": 7, "TV-PG": 10, "TV-14": 14, "TV-MA": 17,
        ],
    ]

    /// Ålder för en certifiering i ett givet land, eller `nil` om den är okänd.
    public static func age(for certification: String, country: String) -> Int? {
        let key = certification.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return tables[country.uppercased()]?[key]
    }

    /// Väljer certifiering: första icke-tomma, mappningsbara värdet för `preferredCountry`, annars `fallback`.
    /// Värdena per land ska vara ordnade i prioritetsordning (t.ex. biopremiär först).
    /// Finns bara okända värden returneras det första av dem med `age == nil`; finns inget alls blir båda `nil`.
    public static func ageLimit(from releaseDates: [String: [String]], preferredCountry: String = "SE",
                                fallback: String = "US") -> (certification: String?, age: Int?) {
        var firstUnknown: String?
        let countries = preferredCountry == fallback ? [preferredCountry] : [preferredCountry, fallback]
        for country in countries {
            for raw in releaseDates[country] ?? [] {
                let cert = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cert.isEmpty else { continue }
                if let age = age(for: cert, country: country) { return (cert, age) }
                if firstUnknown == nil { firstUnknown = cert }
            }
        }
        return (firstUnknown, nil)
    }
}
