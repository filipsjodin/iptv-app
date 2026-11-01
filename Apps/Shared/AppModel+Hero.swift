import Core
import Foundation
import Library
import Metadata
import Playback
import PlaybackCore
import Providers

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
    func hero(for item: Library.LibraryItem, playlistID: UUID) async -> HeroInfo? {
        guard item.kind != .live else { return nil }
        let kids = kidsRestricted
        let key = HeroKey(playlistID: playlistID, kind: item.kind, providerID: item.providerID,
                          kidsRestricted: kids)
        if let cached = heroCache.value(for: key) { return cached }
        let store = store, metadataStore = metadataStore, showExternalRatings = omdbConfigured
        let kind = item.kind, providerID = item.providerID
        // Uppdateras metadata under läsningen (berikning) kan ett åldersbeslut vara föråldrat. Barnläget gör då om
        // hela beslutet en gång till i stället för att lämna ut eller spara det; därefter nekas titeln.
        for _ in 0..<2 {
            // Före åldersprövningen, så att en uppdatering under den också räknas.
            let generation = metadataCacheGeneration
            if kids, !(await canOpenTitle(kind: kind, providerID: providerID, playlistID: playlistID)) { return nil }
            // OBS: `LibraryPerformance.focusToHeroLatencyAt200k` (Packages/IPTVPlatform) speglar den här läsningen
            // (film, tmdbID, metadata); ändras den ska testet ändras med.
            let read = try? await offMain(priority: .utility) { () throws -> HeroRead in
                var container: String?
                if kind == .movie {
                    container = try store.movie(playlistID: playlistID, providerID: providerID)?.container
                }
                guard let id = try metadataStore.tmdbID(playlistID: playlistID, kind: kind, providerID: providerID)
                else { return HeroRead(metadata: nil, container: container) }
                return HeroRead(metadata: try metadataStore.metadata(kind: kind, tmdbID: id), container: container)
            }
            heroAfterReadHook?()
            // Profilen kan ha bytts under läsningen: svaret hör till ett annat åldersfilter än det som gäller nu.
            guard kidsRestricted == kids else { return nil }
            // Barnläge: åldersgränsen i den lästa metadatan prövas också (stängt som standard: okänd eller för hög
            // gräns ger nil), så att ett beslut som hunnit bli föråldrat aldrig bygger en hero.
            if kids {
                guard let age = read?.metadata?.ageLimit, age <= Certification.kidsMaxAge else { return nil }
            }
            let hero = Self.makeHero(item: item, metadata: read?.metadata, container: read?.container,
                                     showExternalRatings: showExternalRatings)
            if generation != metadataCacheGeneration {
                if kids { continue }
                return hero   // föråldrad: används nu men sparas inte
            }
            // Ett läsfel ger reservvärdena men sparas inte.
            if read != nil { heroCache.insert(hero, for: key) }
            return hero
        }
        return nil
    }

    /// Hämtar TMDB-metadata för en titel som ännu inte berikats (annars väntar loggan och backdropen tills
    /// detaljsidan öppnas) och ger den fullständiga heron. `nil` när titeln redan har metadata, när TMDB är
    /// avstängt eller inte hittar titeln, eller när titeln inte får visas i barnläge. Nätanropet delas med
    /// detaljsidan och bakgrundsberikningen (`MetadataService` slår ihop samtidiga anrop), och ett nyligt
    /// misslyckat försök görs inte om.
    func heroAfterFetchingMetadata(for item: Library.LibraryItem, playlistID: UUID) async -> HeroInfo? {
        guard metadataConfigured, item.kind != .live,
              await canOpenTitle(kind: item.kind, providerID: item.providerID, playlistID: playlistID)
        else { return nil }
        let metadataStore = metadataStore
        let kind = item.kind, providerID = item.providerID
        let hasMetadata = try? await offMain(priority: .utility) { () throws -> Bool in
            guard let id = try metadataStore.tmdbID(playlistID: playlistID, kind: kind, providerID: providerID)
            else { return false }
            return try metadataStore.metadata(kind: kind, tmdbID: id) != nil
        }
        // Läsfel (nil) eller redan sparad metadata: inget att hämta.
        guard hasMetadata == false else { return nil }
        guard await metadata.metadata(playlistID: playlistID, kind: kind, providerID: providerID) != nil,
              !Task.isCancelled else { return nil }
        invalidateTitleCaches(playlistID: playlistID, kind: kind, providerID: providerID)
        return await hero(for: item, playlistID: playlistID)
    }

    /// Sätter ihop hero-uppgifterna: titel och år från leverantören, resten ur metadatan när den finns.
    nonisolated static func makeHero(item: Library.LibraryItem, metadata: TitleMetadata?, container: String?,
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

// MARK: - Förhandsvisning (§6.5)

extension AppModel {
    /// Strömmen som förhandsvisas för titeln: filmen, eller för en serie S1E1 (första avsnittet i den lägsta
    /// säsongen). `durationHint` är TMDB:s speltid när metadata finns (startpunkten blir då cirka 10 % in), annars
    /// `nil`. Databasläsningar sker utanför huvudtråden; för en Xtream-serie utan sparade avsnitt hämtas de som vid
    /// uppspelning. `nil` för live, okända titlar, saknad hemlighet och (i barnläge) titlar som inte klarar
    /// åldersfiltret, så att ingen ström någonsin begärs för dem.
    func previewRequest(for item: Library.LibraryItem, playlistID: UUID) async -> PreviewSource? {
        guard item.kind != .live,
              await canOpenTitle(kind: item.kind, providerID: item.providerID, playlistID: playlistID)
        else { return nil }
        let store = store, metadataStore = metadataStore
        let kind = item.kind, providerID = item.providerID
        let locator: StreamLocator
        let container: String?
        switch kind {
        case .movie:
            let found = try? await offMain { try store.movie(playlistID: playlistID, providerID: providerID) }
            guard let movie = found ?? nil else { return nil }
            locator = movie.locator
            container = movie.container ?? Self.container(of: movie.locator)
        case .series:
            guard let all = try? await episodes(for: providerID, playlistID: playlistID),
                  let first = all.min(by: { ($0.season, $0.number) < ($1.season, $1.number) }) else { return nil }
            locator = first.locator
            container = first.container ?? Self.container(of: first.locator)
        case .live:
            return nil
        }
        guard let secret = try? await playbackSecret(for: playlistID),
              let url = try? locator.resolve(with: secret) else { return nil }
        let runtime = try? await offMain(priority: .utility) { () throws -> Int? in
            guard let id = try metadataStore.tmdbID(playlistID: playlistID, kind: kind, providerID: providerID)
            else { return nil }
            return try metadataStore.metadata(kind: kind, tmdbID: id)?.runtimeMinutes
        }
        let minutes = runtime ?? nil
        return PreviewSource(url: url, containerExtension: container,
                             durationHint: minutes.flatMap { $0 > 0 ? Double($0) * 60 : nil })
    }

    /// Förhandsvisningens kontroller med AVPlayer (aldrig VLC), appens anslutningsvakt och den aktiva profilens
    /// inställningar och åldersfilter. Vyn som visar Hem äger instansen och anropar `stop()` när den försvinner.
    func makePreviewController() -> PreviewController {
        PreviewController(dependencies: PreviewController.Dependencies(
            broker: broker,
            makeEngine: { AVPlayerEngine(displayCriteria: PreviewDisplayCriteria()) },
            setMuted: { engine, muted in (engine as? AVPlayerEngine)?.player.isMuted = muted },
            resolve: { [weak self] item, playlistID in
                await self?.previewRequest(for: item, playlistID: playlistID)
            },
            settings: { [weak self] in self?.settings ?? PlaybackSettings() },
            kidsAllowed: { [weak self] item, playlistID in
                guard let self else { return false }
                return await self.canOpenTitle(kind: item.kind, providerID: item.providerID, playlistID: playlistID)
            },
            sleep: { try await Task.sleep(for: $0) },
            resolveChannel: { [weak self] group, playlistID in
                await self?.channelPreviewRequest(group: group, playlistID: playlistID)
            },
            channelAllowed: { [weak self] in
                guard let self else { return false }
                return !self.kidsRestricted && self.activeProfile != nil
            }))
    }

    /// Strömmen som förhandsvisas för en kanalgrupp: bästa varianten för SDR (en liten ruta behöver inte HDR).
    /// Ingen databasåtkomst på huvudtråden; hemligheten läses via den vanliga vägen. `nil` i barnläge, utan aktiv
    /// profil och när hemligheten saknas, så att ingen ström begärs. Ingen längdgräns och ingen startposition.
    func channelPreviewRequest(group: ChannelGroup, playlistID: UUID) async -> PreviewSource? {
        guard !kidsRestricted, activeProfile != nil else { return nil }
        let stream = group.preferred(displaySupportsHDR: false)
        guard let secret = try? await playbackSecret(for: playlistID),
              let url = try? stream.locator.resolve(with: secret) else { return nil }
        return PreviewSource(url: url, containerExtension: Self.container(of: stream.locator), durationHint: nil)
    }
}
