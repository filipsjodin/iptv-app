import Core
import Discovery
import Library

/// Titeln som bannern på Hem lyfter fram (iOS: banner, tvOS: helskärmshero).
struct FeaturedPick: Equatable {
    var item: Library.LibraryItem
}

/// Väljer bannerns titlar ur Hems rader. Ren logik utan UI-typer. Väljer bara ur raderna den får (barnprofilens rader
/// är redan åldersfiltrerade, så inget extra hämtas): titlarna i "För dig", annars i första raden som inte är
/// Fortsätt titta. Tomma rader och live hoppas över.
enum FeaturedPicker {
    static func pick(from rows: [HomeRow]) -> FeaturedPick? {
        picks(from: rows, limit: 1).first
    }

    /// Högst `limit` titlar ur samma rad som `pick` väljer ur (den första titeln är alltid `pick`:s).
    static func picks(from rows: [HomeRow], limit: Int) -> [FeaturedPick] {
        guard limit > 0 else { return [] }
        if let forYou = rows.first(where: { $0.id == .forYou }), let found = titles(in: forYou, limit: limit) {
            return found
        }
        for row in rows where row.id != .continueWatching {
            if let found = titles(in: row, limit: limit) { return found }
        }
        return []
    }

    private static func titles(in row: HomeRow, limit: Int) -> [FeaturedPick]? {
        let found = row.titles.lazy.filter { $0.kind != .live }.prefix(limit).map { FeaturedPick(item: $0) }
        return found.isEmpty ? nil : Array(found)
    }
}
