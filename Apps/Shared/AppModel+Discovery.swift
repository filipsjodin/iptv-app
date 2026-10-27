import Core
import Discovery
import Foundation
import Library
import Metadata
import Personal
import PlaybackCore

// MARK: - Hem, detaljsidor, Min lista och betyg

extension AppModel {
    /// Antal liknande titlar på detaljsidan.
    nonisolated static let similarLimit = 20

    /// Hem för den aktiva profilen: Fortsätt titta först (när det finns), därefter `DiscoveryService.rows` i
    /// tjänstens ordning (filmer och serier). Utan vald profil för spellistan blir det inga rader. Min lista och
    /// betyg läses vid varje anrop, så en ändring syns nästa gång raderna laddas.
    func homeRows(playlistID: UUID) async throws -> [HomeRow] {
        guard let session = activeProfile, session.profile.playlistID == playlistID else { return [] }
        let continueItems = await continueWatching(playlistID: playlistID)
        var rows: [HomeRow] = []
        if !continueItems.isEmpty {
            rows.append(HomeRow(id: .continueWatching, title: Self.rowTitle(.continueWatching, genreName: nil),
                                continueItems: continueItems))
        }
        return rows + (try await discoveryRows(session, playlistID: playlistID, kinds: [.movie, .series]))
    }

    /// Barnläge: den aktiva profilen är en barnprofil, eller ingen profil är vald (stängt som standard).
    var kidsRestricted: Bool { activeProfile?.profile.isKids ?? true }

    /// Filmer- eller Serier-fliken. Vuxna: leverantörens kategorier (plus "Alla"). Barnprofil (eller ingen
    /// profil): aldrig kategorier eller "Alla", bara upptäcktens åldersfiltrerade rader för typen.
    func catalogListing(playlistID: UUID, kind: ContentKind) async throws -> CatalogListing {
        if kidsRestricted {
            guard let session = activeProfile, session.profile.playlistID == playlistID else { return .kids([]) }
            return .kids(try await discoveryRows(session, playlistID: playlistID, kinds: [kind]))
        }
        let store = store
        return .categories(try await offMain { try store.categories(playlistID: playlistID, kind: kind) })
    }

    private func discoveryRows(_ session: ProfileSession, playlistID: UUID,
                               kinds: [ContentKind]) async throws -> [HomeRow] {
        let profile = session.profile, personal = session.personal, state = session.userState
        let discovery = discovery
        let found = try await offMain { () throws -> [(RowID, String?, [LibraryItem])] in
            try discovery.rows(playlistID: playlistID, profile: profile, personal: personal, userState: state,
                               kinds: kinds).map { (id, items) -> (RowID, String?, [LibraryItem]) in
                var genreName: String?
                if case let .genre(genre, _) = id { genreName = discovery.genreName(genre) }
                return (id, genreName, items)
            }
        }
        return found.map { (id, genreName, items) -> HomeRow in
            HomeRow(id: id, title: Self.rowTitle(id, genreName: genreName), titles: items)
        }
    }

    /// Får detaljsidan för titeln visas? I barnläge bara titlar med känd åldersgräns som klarar barnfiltret.
    func canOpenTitle(kind: ContentKind, providerID: String, playlistID: UUID) async -> Bool {
        guard kind != .live else { return false }
        guard kidsRestricted else { return true }
        let discovery = discovery
        let key = ProgressKey(playlistID: playlistID, kind: kind, providerID: providerID,
                              seriesProviderID: kind == .series ? providerID : nil)
        return (try? await offMain { Self.allowedForKids(discovery, key: key) }) ?? false
    }

    /// Radens rubrik.
    nonisolated static func rowTitle(_ id: RowID, genreName: String?) -> String {
        switch id {
        case .continueWatching:
            return String(localized: "Continue Watching")
        case .forYou:
            return String(localized: "For You")
        case .topTen(let kind):
            return kind == .series ? String(localized: "Top 10 Series") : String(localized: "Top 10 Movies")
        case .recentlyAdded(let kind):
            return kind == .series
                ? String(localized: "Recently Added Series") : String(localized: "Recently Added Movies")
        case .myList:
            return String(localized: "My List")
        case let .genre(genre, kind):
            let name = genreName ?? String(localized: "Genre \(genre)")
            return kind == .series ? String(localized: "\(name) · Series") : String(localized: "\(name) · Movies")
        }
    }

    /// Detaljsidans uppgifter: leverantörens titel, år och affisch, kompletterade med TMDB-metadata när den finns
    /// (i cachen, eller hämtad om en TMDB-nyckel finns). `nil` om titeln inte finns i katalogen (eller är live).
    /// I barnläge `nil` för titlar som inte klarar åldersfiltret (även okända och oklassade).
    func titleDetail(kind: ContentKind, providerID: String, playlistID: UUID) async -> TitleDetail? {
        guard kind != .live else { return nil }
        guard await canOpenTitle(kind: kind, providerID: providerID, playlistID: playlistID) else { return nil }
        let store = store
        let found = try? await offMain { () throws -> ProviderTitle? in
            switch kind {
            case .movie:
                return try store.movie(playlistID: playlistID, providerID: providerID)
                    .map { ProviderTitle(title: $0.title, year: $0.year, posterURL: $0.posterURL) }
            case .series:
                return try store.series(playlistID: playlistID, providerID: providerID)
                    .map { ProviderTitle(title: $0.title, year: $0.year, posterURL: $0.posterURL) }
            case .live:
                return nil
            }
        }
        guard let base = found ?? nil else { return nil }
        let meta = await metadata.metadata(playlistID: playlistID, kind: kind, providerID: providerID)
        // Tjänsten kan ha matchat och sparat metadata just nu: affischmissar och reserv-heros för titeln är då
        // föråldrade. (Lästa träffar kostar bara en läsning till; metadata ändras sällan.)
        if meta != nil { invalidateTitleCaches(playlistID: playlistID, kind: kind, providerID: providerID) }
        return TitleDetail.make(kind: kind, providerID: providerID, title: base.title, year: base.year,
                                posterURL: base.posterURL, metadata: meta, showExternalRatings: omdbConfigured)
    }

    /// "Liknande titlar" (barnfiltret för barnprofiler). Tomt vid fel.
    func similarTitles(kind: ContentKind, providerID: String, playlistID: UUID) async -> [LibraryItem] {
        let discovery = discovery, kids = kidsRestricted, limit = Self.similarLimit
        let found = try? await offMain {
            try discovery.similar(playlistID: playlistID, kind: kind, providerID: providerID, limit: limit, kids: kids)
        }
        return found ?? []
    }

    /// "Allt med <namn>": filmer och serier där personen medverkar. Tomt vid fel.
    func titles(withPerson personID: Int, playlistID: UUID) async -> [LibraryItem] {
        let discovery = discovery, kids = kidsRestricted
        let found = try? await offMain {
            try discovery.byPerson(playlistID: playlistID, personID: personID, kids: kids)
        }
        return found ?? []
    }

    /// TMDB-affischen för en titel ur cachad metadata, eller `nil` (då används leverantörens affisch). Både träffar
    /// och uppslag som inte gav något minns, så att ett upprepat anrop (t.ex. när en rad ritas om) inte läser
    /// databasen igen. Minnet rensas för spellistan när dess metadata uppdaterats (`invalidateMetadataCaches`).
    func tmdbPosterURL(for item: LibraryItem, playlistID: UUID) async -> URL? {
        guard item.kind != .live else { return nil }
        let key = "\(playlistID.uuidString)|\(item.id)"
        if let cached = tmdbPosters[key] { return cached }
        if tmdbPosterMisses.contains(key) { return nil }
        let store = metadataStore
        let generation = metadataCacheGeneration
        tmdbPosterReads += 1
        let path: String?
        do {
            path = try await offMain(priority: .utility) { () throws -> String? in
                guard let id = try store.tmdbID(playlistID: playlistID, kind: item.kind, providerID: item.providerID),
                      let meta = try store.metadata(kind: item.kind, tmdbID: id) else { return nil }
                return meta.posterPath
            }
        } catch {
            // Läsfel eller avbrott minns vi inte: nästa anrop försöker igen.
            return nil
        }
        let url = path.flatMap { $0.isEmpty ? nil : TMDBImage.url(path: $0, size: ArtworkKind.poster.tmdbSize) }
        // Har metadata uppdaterats medan vi läste kan svaret vara föråldrat; då sparas det inte.
        if generation == metadataCacheGeneration {
            if let url {
                tmdbPosters[key] = url
            } else {
                if tmdbPosterMisses.count >= tmdbPosterMissLimit { tmdbPosterMisses.removeAll() }
                tmdbPosterMisses.insert(key)
            }
        }
        return url
    }

    /// Metadata för just den här titeln har sparats (t.ex. hämtad när detaljsidan öppnades): glöm dess affischminne
    /// och hero-poster (barnläge och vuxenläge), så att nästa anrop läser den nya metadatan.
    func invalidateTitleCaches(playlistID: UUID, kind: ContentKind, providerID: String) {
        metadataCacheGeneration &+= 1
        let key = "\(playlistID.uuidString)|\(kind.rawValue):\(providerID)"
        tmdbPosterMisses.remove(key)
        tmdbPosters[key] = nil
        heroCache.removeAll { $0.playlistID == playlistID && $0.kind == kind && $0.providerID == providerID }
    }

    /// Spellistans metadata har uppdaterats (berikning, ny import, borttagning): glöm minnet av affischer och
    /// färdiga hero-poster för den, så att nästa anrop läser databasen på nytt.
    func invalidateMetadataCaches(playlistID: UUID) {
        metadataCacheGeneration &+= 1
        let prefix = playlistID.uuidString + "|"
        tmdbPosterMisses = tmdbPosterMisses.filter { !$0.hasPrefix(prefix) }
        tmdbPosters = tmdbPosters.filter { !$0.key.hasPrefix(prefix) }
        heroCache.removeAll { $0.playlistID == playlistID }
    }

    // MARK: Min lista och betyg (aktiv profil)

    func isInMyList(_ ref: ItemRef) -> Bool {
        _ = personalRevision
        return activeProfile?.personal.isInMyList(ref) ?? false
    }

    /// Lägger till eller tar bort titeln ur profilens Min lista. Returnerar om titeln finns i listan efteråt
    /// (alltid `false` utan aktiv profil).
    @discardableResult
    func toggleMyList(_ ref: ItemRef) -> Bool {
        guard let personal = activeProfile?.personal else { return false }
        let inList = personal.toggleMyList(ref)
        personalRevision += 1
        return inList
    }

    func rating(_ ref: ItemRef) -> Rating? {
        _ = personalRevision
        return activeProfile?.personal.rating(ref)
    }

    /// 👍/👎: sätter betyget, eller tar bort det om titeln redan har just det betyget.
    func toggleRating(_ rating: Rating, for ref: ItemRef) {
        guard let personal = activeProfile?.personal else { return }
        personal.setRating(personal.rating(ref) == rating ? nil : rating, for: ref)
        personalRevision += 1
    }
}

private struct ProviderTitle: Sendable {
    let title: String
    let year: Int?
    let posterURL: URL?
}

/// Innehållet i Filmer- eller Serier-fliken (utom sökningen).
enum CatalogListing: Sendable {
    case categories([Core.Category])
    /// Barnprofil: bara åldersfiltrerade rader.
    case kids([HomeRow])
}

/// En rad på Hem. Fortsätt titta har `continueItems` (spelas direkt), övriga rader `titles` (öppnar detaljsidan).
struct HomeRow: Identifiable, Sendable {
    let id: RowID
    let title: String
    var titles: [LibraryItem] = []
    var continueItems: [ContinueWatchingItem] = []
}

/// En person på detaljsidan (skådespelare med roll, eller regissör/serieskapare).
struct PersonCredit: Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let role: String?
}

/// Ett betyg på detaljsidan, t.ex. ("IMDb", "7.8").
struct TitleRating: Hashable, Sendable {
    let source: String
    let value: String
}

extension TitleRating {
    /// Betygen för metadatan i visningsordning (TMDB, IMDb, Rotten Tomatoes). IMDb och Rotten Tomatoes bara med
    /// `showExternalRatings` (OMDb-nyckel finns). Delas av detaljsidan och hero-informationen.
    static func ratings(for metadata: TitleMetadata, showExternalRatings: Bool) -> [TitleRating] {
        var ratings: [TitleRating] = []
        if let vote = metadata.voteAverage, vote > 0 {
            ratings.append(TitleRating(source: "TMDB", value: String(format: "%.1f", vote)))
        }
        if showExternalRatings {
            if let imdb = metadata.imdbRating {
                ratings.append(TitleRating(source: "IMDb", value: String(format: "%.1f", imdb)))
            }
            if let rt = metadata.rottenTomatoes {
                ratings.append(TitleRating(source: "Rotten Tomatoes", value: "\(rt)%"))
            }
        }
        return ratings
    }
}

extension TitleMetadata {
    /// Texten utan omgivande blanka tecken, eller `nil` om den saknas eller blev tom.
    static func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Det detaljsidan visar. Utan metadata: bara leverantörens titel, år och affisch.
struct TitleDetail: Equatable, Sendable {
    let kind: ContentKind
    let providerID: String
    let title: String
    let year: Int?
    let posterURL: URL?
    let overview: String?
    let genres: [String]
    let certification: String?
    let ratings: [TitleRating]
    let cast: [PersonCredit]
    let directors: [PersonCredit]
    let hasMetadata: Bool

    var ref: ItemRef { ItemRef(kind: kind, providerID: providerID) }

    /// Titeln kommer alltid från leverantören (som i katalogen); affischen från TMDB när den finns. IMDb- och
    /// Rotten Tomatoes-betyg visas bara med `showExternalRatings` (OMDb-nyckel finns). Serieskapare räknas som
    /// regissörer.
    static func make(kind: ContentKind, providerID: String, title: String, year: Int?, posterURL: URL?,
                     metadata: TitleMetadata?, showExternalRatings: Bool) -> TitleDetail {
        guard let metadata else {
            return TitleDetail(kind: kind, providerID: providerID, title: title, year: year, posterURL: posterURL,
                               overview: nil, genres: [], certification: nil, ratings: [], cast: [], directors: [],
                               hasMetadata: false)
        }
        var directors: [PersonCredit] = []
        for person in metadata.directors + metadata.creators where !directors.contains(where: { $0.id == person.id }) {
            directors.append(PersonCredit(id: person.id, name: person.name, role: nil))
        }
        return TitleDetail(
            kind: kind, providerID: providerID, title: title, year: year ?? metadata.year,
            posterURL: metadata.posterPath.flatMap {
                $0.isEmpty ? nil : TMDBImage.url(path: $0, size: ArtworkKind.poster.tmdbSize)
            } ?? posterURL,
            overview: TitleMetadata.cleaned(metadata.overview),
            genres: metadata.genres.map(\.name),
            certification: TitleMetadata.cleaned(metadata.certification),
            ratings: TitleRating.ratings(for: metadata, showExternalRatings: showExternalRatings),
            cast: metadata.cast.map { PersonCredit(id: $0.id, name: $0.name, role: $0.character) },
            directors: directors,
            hasMetadata: true)
    }
}
