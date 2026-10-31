import Core
import Foundation
import Observation
import Providers

/// Live-flikens tillstånd: sektioner (Favoriter, Senast sedda, kategorier) och "Nu/Nästa" per kanalgrupp.
/// All databas- och Keychain-åtkomst går via `AppModel+Live` utanför huvudaktören.
@MainActor @Observable
final class LiveModel {
    struct Section: Identifiable {
        enum Kind: Equatable {
            case favorites
            case recents
            /// Leverantörens kategori-id (tom sträng för kanaler utan känd kategori).
            case category(String)
        }

        let id: String
        let title: String
        let groups: [ChannelGroup]
        let kind: Kind
    }

    private(set) var sections: [Section] = []
    /// Pågående och nästa program per kanalgrupp (grupp-id).
    private(set) var nowNext: [String: NowNext] = [:]
    private(set) var loading = true
    private(set) var failed = false
    /// Kanalgrupperna som är synliga just nu (vyn rapporterar raderna som visas).
    private(set) var visibleIDs: Set<String> = []
    /// Favoritkanalernas grupp-id (för menyvalet och stjärnmarkeringen).
    private(set) var favoriteIDs: Set<String> = []

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored let playlistID: UUID
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var groups: [ChannelGroup] = [] {
        didSet { groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// Grupp-id → grupp (byggs när grupperna läses, för uppslag utan sökning).
    @ObservationIgnored private(set) var groupsByID: [String: ChannelGroup] = [:]
    @ObservationIgnored private var categories: [Core.Category] = []
    /// Grupp-id → XMLTV-kanal för grupper med lagrad tablå.
    @ObservationIgnored private var epgIDs: [String: String] = [:] {
        didSet { epgVersion += 1 }
    }
    /// Ökas när kopplingen grupp → XMLTV-kanal lästs om (tablårutnätet läser om sina rader då).
    private(set) var epgVersion = 0

    init(model: AppModel, playlistID: UUID, now: @escaping @Sendable () -> Date = Date.init) {
        self.model = model
        self.playlistID = playlistID
        self.now = now
    }

    /// XMLTV-kanalen för en kanalgrupp (två grupper kan dela en). `nil` utan lagrad tablåkoppling.
    func epgChannelID(for groupID: String) -> String? { epgIDs[groupID] }

    /// Alla kanalgrupper (för att slå upp en grupp ur ett id).
    var allGroups: [ChannelGroup] { groups }

    /// Läser grupper, kategorier och tablåkoppling, startar tablåhämtningen om den behövs och läser "Nu/Nästa" för
    /// de synliga raderna. Barnläge: inga sektioner.
    func load() async {
        loading = true
        defer { loading = false }
        guard !model.kidsRestricted else {
            groups = []
            sections = []
            nowNext = [:]
            failed = false
            return
        }
        do {
            let loaded = try await model.liveGroups(playlistID: playlistID)
            let loadedCategories = await model.liveCategories(playlistID: playlistID)
            guard !Task.isCancelled else { return }
            groups = loaded
            categories = loadedCategories
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = true
            return
        }
        rebuildSections()
        epgIDs = await model.epgMap(playlistID: playlistID, groups: groups)
        guard !Task.isCancelled else { return }
        // Hämtningen körs i bakgrunden; `AppModel.epgRevision` ökas när den sparat nya program.
        await model.refreshEPGIfNeeded(playlistID: playlistID)
        await refreshNowNext(for: visibleGroups)
    }

    /// Bygger om sektionerna ur de redan lästa grupperna (favoriter och senast sedda lästs på nytt).
    func rebuildSections() {
        let favorites = model.favoriteChannelIDs()
        favoriteIDs = Set(favorites)
        sections = Self.buildSections(groups: groups, categories: categories, favoriteIDs: favorites,
                                      recentIDs: model.recentChannelIDs())
    }

    func toggleFavorite(_ group: ChannelGroup) {
        model.toggleFavoriteChannel(group.id)
        rebuildSections()
    }

    /// Noterar att kanalen spelas. Sektionerna byggs om först när spelaren stängts (`rebuildSections`).
    func noteWatched(_ group: ChannelGroup) {
        model.noteChannelWatched(group.id)
    }

    /// Ny tablå har sparats: läs om kopplingen och "Nu/Nästa".
    func epgUpdated() async {
        guard !model.kidsRestricted else { return }
        epgIDs = await model.epgMap(playlistID: playlistID, groups: groups)
        await refreshNowNext(for: visibleGroups)
    }

    func setVisible(_ ids: Set<String>) {
        if ids != visibleIDs { visibleIDs = ids }
    }

    var visibleGroups: [ChannelGroup] { groups.filter { visibleIDs.contains($0.id) } }

    /// Läser "Nu/Nästa" för de angivna (synliga) kanalerna: lagrad tablå först, för Xtream-kanaler utan program
    /// nu den korta tablån. Anropas när de synliga raderna ändras och var 60:e sekund. Andra kanalers värden rörs inte.
    func refreshNowNext(for visible: [ChannelGroup]) async {
        guard !model.kidsRestricted else {
            nowNext = [:]
            return
        }
        guard !visible.isEmpty else { return }
        let date = now()
        let mapped = visible.compactMap { group in epgIDs[group.id].map { (groupID: group.id, xmltvID: $0) } }
        let stored = await model.nowNext(playlistID: playlistID, xmltvIDs: mapped.map(\.xmltvID), at: date)
        var updated: [String: NowNext] = [:]
        for item in mapped {
            if let value = stored[item.xmltvID], value.now != nil { updated[item.groupID] = value }
        }
        let missing = visible.filter { updated[$0.id] == nil }
        let fallback = await model.shortNowNext(playlistID: playlistID, groups: missing, at: date)
        guard !Task.isCancelled else { return }
        updated.merge(fallback) { current, _ in current }
        // En kanal med bara "nästa" i lagrad tablå behåller det om reserven inte hittar något.
        for item in mapped where updated[item.groupID] == nil {
            if let value = stored[item.xmltvID] { updated[item.groupID] = value }
        }
        var result = nowNext
        for group in visible { result[group.id] = updated[group.id] }
        nowNext = result
    }

    /// Delar upp (eller slår ihop) en variant och läser om grupperna.
    func split(providerID: String, split: Bool) async {
        await model.splitChannel(playlistID: playlistID, providerID: providerID, split: split)
        await load()
    }

    // MARK: Sektioner

    /// Ordning: Favoriter, Senast sedda, därefter kategorier i leverantörens ordning. Tomma sektioner utelämnas.
    /// En grupp tillhör sin egen kategori; favoriter och senast sedda är kopior. Grupper utan känd kategori hamnar i
    /// en sista sektion. `favoriteIDs` och `recentIDs` är nyast först; okända id:n (t.ex. efter en uppdelning)
    /// hoppas över.
    nonisolated static func buildSections(groups: [ChannelGroup], categories: [Core.Category], favoriteIDs: [String],
                                          recentIDs: [String]) -> [Section] {
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Section] = []

        let favorites = favoriteIDs.compactMap { byID[$0] }
        if !favorites.isEmpty {
            result.append(Section(id: "favorites", title: String(localized: "Favorites"), groups: favorites,
                                  kind: .favorites))
        }
        let recents = recentIDs.compactMap { byID[$0] }
        if !recents.isEmpty {
            result.append(Section(id: "recents", title: String(localized: "Recently watched"), groups: recents,
                                  kind: .recents))
        }

        var byCategory: [String: [ChannelGroup]] = [:]
        for group in groups { byCategory[group.variants.first?.categoryID ?? "", default: []].append(group) }
        var used: Set<String> = []
        for category in categories {
            guard used.insert(category.providerID).inserted,
                  let members = byCategory[category.providerID], !members.isEmpty else { continue }
            result.append(Section(id: "category/\(category.providerID)", title: category.name, groups: members,
                                  kind: .category(category.providerID)))
        }
        let other = groups.filter { !used.contains($0.variants.first?.categoryID ?? "") }
        if !other.isEmpty {
            result.append(Section(id: "category/", title: String(localized: "Other"), groups: other,
                                  kind: .category("")))
        }
        return result
    }
}
