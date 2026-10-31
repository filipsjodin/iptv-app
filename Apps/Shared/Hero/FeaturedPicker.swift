#if !os(tvOS)
import Core
import Discovery
import Library

/// Titeln som bannern på Hem (iOS) lyfter fram.
struct FeaturedPick: Equatable {
    var item: Library.LibraryItem
}

/// Väljer bannerns titel ur Hems rader. Ren logik utan UI-typer. Väljer bara ur raderna den får (barnprofilens rader
/// är redan åldersfiltrerade, så inget extra hämtas): första titeln i "För dig", annars första titeln i första raden
/// som inte är Fortsätt titta. Tomma rader och live hoppas över.
enum FeaturedPicker {
    static func pick(from rows: [HomeRow]) -> FeaturedPick? {
        if let forYou = rows.first(where: { $0.id == .forYou }), let found = first(in: forYou) {
            return found
        }
        for row in rows where row.id != .continueWatching {
            if let found = first(in: row) { return found }
        }
        return nil
    }

    private static func first(in row: HomeRow) -> FeaturedPick? {
        row.titles.first { $0.kind != .live }.map { FeaturedPick(item: $0) }
    }
}
#endif
