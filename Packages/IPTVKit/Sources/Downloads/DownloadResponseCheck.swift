import Foundation

/// Avgör om ett HTTP-svar på en nedladdning kan vara en video. Ren logik utan I/O; felen är fasta värden utan
/// servertext eller URL.
public enum DownloadResponseCheck {
    /// Golv för en trovärdig videofil. Felsidor och JSON-svar är långt mindre.
    public static let minimumPlausibleBytes: Int64 = 64 * 1024

    /// `nil` om svaret ser ut som en fil. 401/403 är `expired` (abonnemang eller uppgifter har slutat gälla),
    /// övriga svar utanför 2xx (och svar utan HTTP-status) är `badStatus`, HTML-svar är `badContent`.
    public static func failure(status: Int, contentType: String?) -> DownloadFailure? {
        if status == 401 || status == 403 { return .expired }
        guard (200..<300).contains(status) else { return .badStatus }
        if isMarkup(contentType) { return .badContent }
        return nil
    }

    /// Minsta storlek för att en fil ska räknas som färdig. Känd förväntad storlek ger halva den (en uppskattning
    /// får inte fälla en riktig fil), men aldrig mer än golvet och aldrig mindre än en byte.
    public static func minimumBytes(expectedBytes: Int64?) -> Int64 {
        guard let expected = expectedBytes, expected > 0 else { return minimumPlausibleBytes }
        return min(minimumPlausibleBytes, max(1, expected / 2))
    }

    private static func isMarkup(_ contentType: String?) -> Bool {
        guard let type = contentType?.lowercased()
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces) else { return false }
        return type == "text/html" || type == "application/xhtml+xml"
    }
}
