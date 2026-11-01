import Foundation

/// Sidomenyns tillstånd på kategorisidan. Ren logik utan plattformsberoenden, så att den också kompileras av
/// iOS-testmålet.
struct CatalogMenuState: Equatable {
    private(set) var isOpen = false
    /// Posten som har fokus i menyn.
    private(set) var focusedEntryID: String?
    /// Senast valda rad (rullningsmål).
    private(set) var selectedSectionID: String?
    /// Sektionen menyn öppnades från; kan vara `nil` eller saknas bland menyposterna.
    private var originSectionID: String?

    /// Öppnar menyn med fokus på `sectionID` om den finns i `entries`, annars på första posten. Tom `entries` öppnar
    /// inte menyn.
    mutating func open(from sectionID: String?, entries: [CatalogMenuEntry]) {
        guard let first = entries.first else { return }
        originSectionID = sectionID
        selectedSectionID = nil
        if let sectionID, entries.contains(where: { $0.id == sectionID }) {
            focusedEntryID = sectionID
        } else {
            focusedEntryID = first.id
        }
        isOpen = true
    }

    /// Väljer en post: rullningsmålet och fokus i menyn flyttas dit, men menyn stängs inte.
    mutating func select(_ entryID: String) {
        selectedSectionID = entryID
        focusedEntryID = entryID
    }

    /// Stänger menyn och returnerar sektionen fokus ska till: den senast valda, annars den menyn öppnades från (kan
    /// vara `nil` eller inte en menypost; anroparen hanterar det). Nollställer valet.
    mutating func close() -> String? {
        let target = selectedSectionID ?? originSectionID
        isOpen = false
        focusedEntryID = nil
        selectedSectionID = nil
        originSectionID = nil
        return target
    }
}
