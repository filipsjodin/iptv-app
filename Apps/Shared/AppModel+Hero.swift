import Core
import Foundation
import Library
import Metadata

// MARK: - Hero-data (stor bakgrund, logga och uppgifter för den fokuserade titeln)

/// Det hero-ytan visar för en titel. Allt utom titeln kan saknas: utan metadata, backdrop eller logga visas
/// leverantörens titel och affisch (`posterURL`) i stället.
struct HeroInfo: Equatable, Sendable {
    let kind: ContentKind
    let providerID: String
    let title: String
    let year: Int?
    let runtimeMinutes: Int?
    let certification: String?
    let ratings: [TitleRating]
    let overview: String?
    let backdropURL: URL?
    let logoURL: URL?
    let badges: [QualityBadge]
    /// TMDB-affischen när den finns, annars leverantörens: reserv när `backdropURL` saknas.
    let posterURL: URL?
}

/// Nyckeln till en färdig hero. Barnläget ingår, så att en hero som cachats för en profil aldrig lämnas ut till en
/// profil med annat åldersfilter (barnprofiler och vuxenprofiler får aldrig dela poster).
struct HeroKey: Hashable, Sendable {
    let playlistID: UUID
    let kind: ContentKind
    let providerID: String
    let kidsRestricted: Bool
}

/// LRU-cache för färdiga hero-poster. Senast använda sist; äldsta posten ryker när `capacity` överskrids.
struct HeroCache {
    static let defaultCapacity = 200

    let capacity: Int
    private var entries: [HeroKey: HeroInfo] = [:]
    /// Äldst först.
    private var order: [HeroKey] = []

    init(capacity: Int = HeroCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    /// Posten, som då räknas som senast använd.
    mutating func value(for key: HeroKey) -> HeroInfo? {
        guard let hero = entries[key] else { return nil }
        touch(key)
        return hero
    }

    mutating func insert(_ hero: HeroInfo, for key: HeroKey) {
        entries[key] = hero
        touch(key)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }

    mutating func removeAll(where shouldRemove: (HeroKey) -> Bool) {
        order.removeAll(where: shouldRemove)
        entries = entries.filter { !shouldRemove($0.key) }
    }

    private mutating func touch(_ key: HeroKey) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }
}

/// Det en hero-läsning ger: TMDB-metadata (om titeln är matchad och metadatan sparad) och filmens container.
private struct HeroRead: Sendable {
    let metadata: TitleMetadata?
    let container: String?
}

extension AppModel {
    /// Hero-uppgifterna för en film eller serie. Metadata läses ur databasen utanför huvudtråden (aldrig från
    /// nätverket), och färdiga poster cachas (LRU 200) per spellista, typ, titel och barnläge.
    ///
    /// Saknas metadata, backdrop eller logga returneras ändå en `HeroInfo` med leverantörens titel och affisch och
    /// `nil` för det som saknas. `nil` för live, och i barnläge för titlar som inte klarar åldersfiltret (även
    /// oklassade: stängt som standard).
    func hero(for item: LibraryItem, playlistID: UUID) async -> HeroInfo? {
        guard item.kind != .live else { return nil }
        let kids = kidsRestricted
        let key = HeroKey(playlistID: playlistID, kind: item.kind, providerID: item.providerID,
                          kidsRestricted: kids)
        if let cached = heroCache.value(for: key) { return cached }
        if kids, !(await canOpenTitle(kind: item.kind, providerID: item.providerID, playlistID: playlistID)) {
            return nil
        }
        let store = store, metadataStore = metadataStore, showExternalRatings = omdbConfigured
        let generation = metadataCacheGeneration
        let kind = item.kind, providerID = item.providerID
        let read = try? await offMain(priority: .utility) { () throws -> HeroRead in
            var container: String?
            if kind == .movie { container = try store.movie(playlistID: playlistID, providerID: providerID)?.container }
            guard let id = try metadataStore.tmdbID(playlistID: playlistID, kind: kind, providerID: providerID) else {
                return HeroRead(metadata: nil, container: container)
            }
            return HeroRead(metadata: try metadataStore.metadata(kind: kind, tmdbID: id), container: container)
        }
        // Profilen kan ha bytts under läsningen: svaret hör till ett annat åldersfilter än det som gäller nu.
        guard kidsRestricted == kids else { return nil }
        let hero = Self.makeHero(item: item, metadata: read?.metadata, container: read?.container,
                                 showExternalRatings: showExternalRatings)
        // Ett läsfel ger reservvärdena men sparas inte; inte heller om metadata uppdaterats under läsningen.
        if read != nil, generation == metadataCacheGeneration { heroCache.insert(hero, for: key) }
        return hero
    }

    /// Sätter ihop hero-uppgifterna: titel och år från leverantören, resten ur metadatan när den finns.
    nonisolated static func makeHero(item: LibraryItem, metadata: TitleMetadata?, container: String?,
                                     showExternalRatings: Bool) -> HeroInfo {
        func image(_ path: String?, _ kind: ArtworkKind) -> URL? {
            guard let path, !path.isEmpty else { return nil }
            return TMDBImage.url(path: path, size: kind.tmdbSize)
        }
        let badges = QualityBadges.parse(title: item.title, containerExtension: container)
        guard let metadata else {
            return HeroInfo(kind: item.kind, providerID: item.providerID, title: item.title, year: item.year,
                            runtimeMinutes: nil, certification: nil, ratings: [], overview: nil, backdropURL: nil,
                            logoURL: nil, badges: badges, posterURL: item.posterURL)
        }
        return HeroInfo(kind: item.kind, providerID: item.providerID, title: item.title,
                        year: item.year ?? metadata.year, runtimeMinutes: metadata.runtimeMinutes,
                        certification: TitleMetadata.cleaned(metadata.certification),
                        ratings: TitleRating.ratings(for: metadata, showExternalRatings: showExternalRatings),
                        overview: TitleMetadata.cleaned(metadata.overview),
                        backdropURL: image(metadata.backdropPath, .backdrop), logoURL: image(metadata.logoPath, .logo),
                        badges: badges, posterURL: image(metadata.posterPath, .poster) ?? item.posterURL)
    }
}
