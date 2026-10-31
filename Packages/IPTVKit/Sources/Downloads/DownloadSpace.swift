import Foundation

public enum DownloadSpace {
    /// Får en nedladdning starta? Det lediga utrymmet minus marginalen ska rymma förväntad storlek. Okänd
    /// (eller icke-positiv) storlek tillåts om marginalen ändå finns kvar.
    public static func canStart(expectedBytes: Int64?, freeBytes: Int64, reserveBytes: Int64) -> Bool {
        let usable = freeBytes
        guard usable >= 0 else { return false }
        let reserve = max(0, reserveBytes)
        guard usable >= reserve else { return false }
        guard let expected = expectedBytes, expected > 0 else { return true }
        return usable - reserve >= expected
    }
}
