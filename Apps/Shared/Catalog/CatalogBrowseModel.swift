import Core
import Foundation
import Library
import Observation

/// En rad på kategorisidan (Filmer- och Serier-flikarna på tvOS): en leverantörskategori som laddas lätt när den
/// kommer nära bild, eller en färdig barnrad.
struct CatalogSection: Identifiable, Equatable {
    enum Phase: Equatable {
        case unloaded
        case loading
        case loaded(items: [Library.LibraryItem], hasMore: Bool)
    }

    /// `"cat:<providerID>"` för kategorier, `"kids:<index>"` för barnrader.
    let id: String
    let title: String
    /// Leverantörens kategori-id; `nil` för barnrader (de är redan laddade).
    let categoryID: String?
    var phase: Phase
}

/// En post i sidomenyn (samma id som sektionen den hoppar till).
struct CatalogMenuEntry: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Modellen bakom kategorisidan: sektioner (en per kategori eller barnrad) med lata rader och menyposter. Ren logik
/// utan plattformsberoenden, så att den också kompileras av iOS-testmålet.
@MainActor @Observable
final class CatalogBrowseModel {
    /// Antal titlar som visas per rad; en titel till hämtas för att veta om det finns fler.
    static let rowLimit = 20

    /// Hämtar de första `limit` titlarna i en kategori.
    typealias Loader = @Sendable (_ categoryID: String, _ limit: Int) async throws -> [Library.LibraryItem]

    private(set) var sections: [CatalogSection] = []

    /// Ökas av `configure`; ett svar som kommer efter en ny konfiguration kastas.
    @ObservationIgnored private var generation = 0

    /// Sidomenyn: alla sektioner utom de som är laddade men tomma.
    var menuEntries: [CatalogMenuEntry] {
        sections.compactMap { section in
            if case let .loaded(items, _) = section.phase, items.isEmpty { return nil }
            return CatalogMenuEntry(id: section.id, title: section.title)
        }
    }

    /// Bygger om sektionerna från flikens innehåll och nollställer pågående laddningar. Kategorier börjar olästa;
    /// barnrader är redan laddade (rader utan titlar utelämnas).
    func configure(_ listing: CatalogListing) {
        generation += 1
        switch listing {
        case .categories(let categories):
            sections = categories.map { category in
                CatalogSection(id: "cat:\(category.providerID)", title: category.name,
                               categoryID: category.providerID, phase: .unloaded)
            }
        case .kids(let rows):
            sections = rows.filter { !$0.titles.isEmpty }.enumerated().map { index, row in
                CatalogSection(id: "kids:\(index)", title: row.title, categoryID: nil,
                               phase: .loaded(items: row.titles, hasMore: false))
            }
        }
    }

    /// Laddar en kategorirad (en gång). Gör inget om sektionen saknas, är en barnrad eller redan är laddad eller
    /// laddas. Vid fel eller avbrott blir raden oläst igen, så att ett nytt försök är möjligt.
    func load(sectionID: String, using loader: Loader) async {
        guard let index = sections.firstIndex(where: { $0.id == sectionID }),
              let categoryID = sections[index].categoryID,
              sections[index].phase == .unloaded else { return }
        sections[index].phase = .loading
        let started = generation
        let phase: CatalogSection.Phase
        do {
            let items = try await loader(categoryID, Self.rowLimit + 1)
            phase = .loaded(items: Array(items.prefix(Self.rowLimit)), hasMore: items.count > Self.rowLimit)
        } catch {
            phase = .unloaded
        }
        // Har sidan konfigurerats om under tiden hör svaret till en sektion som inte längre finns.
        guard started == generation, let current = sections.firstIndex(where: { $0.id == sectionID }) else { return }
        sections[current].phase = phase
    }

    func section(id: String) -> CatalogSection? {
        sections.first { $0.id == id }
    }

    /// Första titelns id i en laddad rad, annars `nil`.
    func firstItemID(inSection id: String) -> String? {
        guard case let .loaded(items, _)? = section(id: id)?.phase else { return nil }
        return items.first?.id
    }
}
