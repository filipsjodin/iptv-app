import Foundation
import Library
import Observation
import os
import Personal
import SwiftUI

extension HeroInfo {
    /// Titelns nyckel i Min lista och betyg.
    var ref: ItemRef { ItemRef(kind: kind, providerID: providerID) }
}

/// Tillståndet bakom Hems hero-yta på tvOS: heron för den fokuserade titeln och förhämtningen av bilder runt
/// fokus. Delas av alla plattformar; bara layouten ligger bakom `#if os(tvOS)`.
///
/// - `current` ersätts först när den nya heron har kommit (den förra ligger kvar, så ytan aldrig blinkar tom). Ett
///   svar för en ersatt fokus ignoreras (jämförs med en löpande token efter `await`).
/// - Förhämtningsfönstret räknas ut av den rena funktionen `plan` och diffas mot det förra: `prefetch` anropas bara
///   för nya adresser och `cancelPrefetch` bara för bortfallna, så att anropen alltid är parade. `reset()` avbryter
///   allt.
@MainActor @Observable
final class HeroModel {
    /// Hur många rader som syns samtidigt i nedre halvan.
    static let visibleRows = 2
    /// Rader utanför det synliga (en skärm) åt vardera håll.
    static let rowMargin = 1
    /// Affischer per rad (ungefär en skärmbredd), räknat från fokuserad titel i fokuserad rad.
    static let postersPerRow = 10
    /// Backdrop för fokuserad titel ± så här många titlar.
    static let backdropRadius = 3

    typealias Loader = @MainActor (Library.LibraryItem, UUID) async -> HeroInfo?
    /// Hämtar TMDB-metadata för en fokuserad titel som saknar den (nätanrop) och ger den nya heron, eller `nil` när
    /// inget ändrades. Körs först efter att den snabba heron visats, så att Spela aldrig väntar på nätet.
    typealias Enricher = @MainActor (Library.LibraryItem, UUID) async -> HeroInfo?
    /// Den TMDB-affisch kortet visar för titeln om den redan är känd (cachad i minnet), annars `nil`. Synkron och
    /// utan databasläsning: anropas på huvudtråden vid varje fönsterflytt.
    typealias PosterResolver = @MainActor (Library.LibraryItem, UUID) -> URL?

    /// Det som ska förhämtas för en fokusposition.
    struct PrefetchPlan: Equatable {
        /// Leverantörens affischadresser för fönstret.
        var posters: Set<URL>
        /// Titlarna bakom `posters`, så att kortens visade affisch (TMDB när den är känd) kan förhämtas i stället.
        var posterItems: [Library.LibraryItem] = []
        var backdropItems: [Library.LibraryItem]
    }

    private(set) var current: HeroInfo?

    @ObservationIgnored private var loader: Loader
    @ObservationIgnored private var posterResolver: PosterResolver
    @ObservationIgnored private var enricher: Enricher
    /// Hur länge fokus ska ha stått stilla innan nätverk och databas används för grannar och saknad metadata. Vid
    /// snabb bläddring byter fokus många gånger per sekund; utan väntan startas (och avbryts) sju databasläsningar,
    /// bakgrundsnedladdningar och en TMDB-hämtning per steg.
    @ObservationIgnored private let settleDelay: Duration
    @ObservationIgnored private let pipeline: ArtworkPipeline
    @ObservationIgnored private var focusToken = 0
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    /// Förhämtade adresser just nu (för diffen och för `reset`).
    @ObservationIgnored private var posterWindow: Set<URL> = []
    @ObservationIgnored private var backdropWindow: Set<URL> = []
    @ObservationIgnored private var windowToken = 0
    /// Löser backdropadresserna för grannarna; testerna väntar in den.
    @ObservationIgnored private(set) var backdropTask: Task<Void, Never>?

    private static let signposter = OSSignposter(subsystem: "se.sjodin.iptv", category: "hero")

    init(pipeline: ArtworkPipeline = .shared, loader: @escaping Loader = { _, _ in nil },
         posterResolver: @escaping PosterResolver = { _, _ in nil },
         enricher: @escaping Enricher = { _, _ in nil }, settleDelay: Duration = .milliseconds(350)) {
        self.settleDelay = settleDelay
        self.pipeline = pipeline
        self.loader = loader
        self.posterResolver = posterResolver
        self.enricher = enricher
    }

    /// Kopplar produktionsladdaren: `AppModel.hero` (databasläsning utanför huvudtråden, barnfilter, cache).
    func attach(_ model: AppModel) {
        loader = { [weak model] item, playlistID in await model?.hero(for: item, playlistID: playlistID) }
        posterResolver = { [weak model] item, playlistID in model?.cachedTMDBPosterURL(for: item, playlistID: playlistID) }
        enricher = { [weak model] item, playlistID in
            await model?.heroAfterFetchingMetadata(for: item, playlistID: playlistID)
        }
    }

    /// Övertoningen mellan hero-bilder; ingen animation med Minska rörelse.
    static func crossfade(reduceMotion: Bool) -> Animation? {
        Motion.animation(Motion.crossfade, reduceMotion: reduceMotion)
    }

    // MARK: Fokus

    /// Fokus flyttades till `item`. `nil` (fokus lämnade raderna) behåller heron men ersätter pågående laddning.
    /// En titel utan hero (barnläge nekar, live) tömmer `current`, så att Spela och Min lista aldrig verkar på en
    /// annan titel än den fokuserade.
    @discardableResult
    func focus(_ item: Library.LibraryItem?, playlistID: UUID) -> Task<Void, Never> {
        focusToken &+= 1
        let token = focusToken
        focusTask?.cancel()
        guard let item else {
            let done = Task {}
            focusTask = done
            return done
        }
        let loader = loader, enricher = enricher, settleDelay = settleDelay
        let task = Task { [weak self] in
            let signposter = Self.signposter
            let state = signposter.beginInterval("hero.focus")
            let hero = await loader(item, playlistID)
            signposter.endInterval("hero.focus", state)
            guard let self, self.focusToken == token else { return }
            self.current = hero
            // Titeln saknar metadata (inte berikad än): hämta den nu och byt till den fullständiga heron, om fokus
            // fortfarande ligger kvar. Loggan och backdropen kommer då utan att detaljsidan behöver öppnas.
            guard hero != nil else { return }
            // Först när fokus står stilla: snabb bläddring över många titlar hämtar inget för de som passeras.
            try? await Task.sleep(for: settleDelay)
            guard !Task.isCancelled, self.focusToken == token, let enriched = await enricher(item, playlistID)
            else { return }
            guard self.focusToken == token else { return }
            self.current = enriched
        }
        focusTask = task
        return task
    }

    /// Hem försvinner: släpper allt (avbryter laddning och förhämtning, tömmer heron).
    func reset() {
        focusToken &+= 1
        focusTask?.cancel()
        focusTask = nil
        current = nil
        windowToken &+= 1
        backdropTask?.cancel()
        backdropTask = nil
        apply(posters: [], backdrops: [])
    }

    // MARK: Förhämtning

    /// Det som ska förhämtas: affischer för de synliga raderna ± en rad (de `postersPerRow` första, i den fokuserade
    /// raden från fokuserad titel), och backdrop för fokuserad titel ± `backdropRadius`. Fortsätt titta har inga
    /// affischer. Ren funktion.
    static func plan(rows: [HomeRow], focusedRow: Int, focusedIndex: Int) -> PrefetchPlan {
        guard rows.indices.contains(focusedRow) else { return PrefetchPlan(posters: [], backdropItems: []) }
        let first = max(0, focusedRow - rowMargin)
        let last = min(rows.count - 1, focusedRow + visibleRows - 1 + rowMargin)
        var posters = Set<URL>()
        var posterItems: [Library.LibraryItem] = []
        for index in first...last {
            let titles = rows[index].titles
            let count = index == focusedRow ? max(0, focusedIndex) + postersPerRow : postersPerRow
            for item in titles.prefix(count) {
                if let url = item.posterURL {
                    posters.insert(url)
                    posterItems.append(item)
                }
            }
        }
        let titles = rows[focusedRow].titles
        var backdropItems: [Library.LibraryItem] = []
        if !titles.isEmpty {
            let center = min(max(0, focusedIndex), titles.count - 1)
            let range = max(0, center - backdropRadius)...min(titles.count - 1, center + backdropRadius)
            backdropItems = Array(titles[range])
        }
        return PrefetchPlan(posters: posters, posterItems: posterItems, backdropItems: backdropItems)
    }

    /// Flyttar förhämtningsfönstret till fokuspositionen. Affischerna diffas direkt; backdropadresserna kräver
    /// hero-uppgifter för grannarna (ur hero-cachen eller en läsning utanför huvudtråden) och följer i en task.
    func prefetchWindow(rows: [HomeRow], focusedRow: Int, focusedIndex: Int = 0, playlistID: UUID) {
        let plan = Self.plan(rows: rows, focusedRow: focusedRow, focusedIndex: focusedIndex)
        windowToken &+= 1
        let token = windowToken
        backdropTask?.cancel()
        // Samma adress som kortet visar: TMDB-affischen när den är känd, annars leverantörens.
        let resolver = posterResolver
        let posters = Set(plan.posterItems.compactMap { resolver($0, playlistID) ?? $0.posterURL })
        apply(posters: posters, backdrops: nil)
        let loader = loader, settleDelay = settleDelay
        backdropTask = Task { [weak self] in
            // Grannarnas hero-data och bakgrunder behövs först när fokus har slutat flytta sig.
            try? await Task.sleep(for: settleDelay)
            var urls = Set<URL>()
            for item in plan.backdropItems {
                if Task.isCancelled { return }
                if let url = await loader(item, playlistID)?.backdropURL { urls.insert(url) }
            }
            guard let self, !Task.isCancelled, self.windowToken == token else { return }
            self.apply(posters: nil, backdrops: urls)
        }
    }

    /// Byter ut fönstret (nil = oförändrat) och anropar pipelinen bara för skillnaden.
    private func apply(posters: Set<URL>?, backdrops: Set<URL>?) {
        if let posters {
            pipeline.prefetch(Array(posters.subtracting(posterWindow)), kind: .poster)
            pipeline.cancelPrefetch(Array(posterWindow.subtracting(posters)), kind: .poster)
            posterWindow = posters
        }
        if let backdrops {
            pipeline.prefetch(Array(backdrops.subtracting(backdropWindow)), kind: .backdrop)
            pipeline.cancelPrefetch(Array(backdropWindow.subtracting(backdrops)), kind: .backdrop)
            backdropWindow = backdrops
        }
    }
}
