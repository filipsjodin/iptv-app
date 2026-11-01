import Core
import Foundation
import Library
import Metadata
import Observation
import Personal
import PlaybackCore
import Providers

/// Rena hjälpfunktioner för detaljsidan (inga vyer, inget nät), så att de kan testas direkt.
enum DetailPresentation {
    /// Återstående tid i heltal: minuter under en timme, annars timmar och minuter.
    enum Remaining: Equatable {
        case minutes(Int)
        case hoursMinutes(Int, Int)
    }

    /// Återstående tid för `seconds`, avrundad uppåt till hela minuter. `nil` när inget återstår eller värdet inte är
    /// ett ändligt tal.
    nonisolated static func remaining(seconds: Double) -> Remaining? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes >= 60 ? .hoursMinutes(minutes / 60, minutes % 60) : .minutes(minutes)
    }

    /// "32 min", "1 h 5 min" eller "1 h" i användarens språk.
    nonisolated static func remainingText(_ remaining: Remaining) -> String {
        switch remaining {
        case .minutes(let m):
            return String(localized: "\(m) min")
        case .hoursMinutes(let h, let m):
            return m == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(m) min")
        }
    }

    /// Huvudknappens text vid pågående titel: "Fortsätt S2:E4 · 32 min kvar". Utan avsnitt (film) "Fortsätt · 32 min
    /// kvar"; utan känd längd bara "Fortsätt S2:E4" eller "Fortsätt".
    static func continueLabel(episode: String?, remaining seconds: Double?) -> String {
        let left = seconds.flatMap(remaining(seconds:)).map(remainingText)
        switch (episode, left) {
        case let (episode?, left?):
            return String(localized: "Continue \(episode) · \(left) left")
        case let (nil, left?):
            return String(localized: "Continue · \(left) left")
        case let (episode?, nil):
            return String(localized: "Continue \(episode)")
        case (nil, nil):
            return String(localized: "Continue")
        }
    }

    /// Betyget efter ett tryck på 👍 eller 👎: samma betyg igen tar bort det, det andra byter. Upprepade tryck ger
    /// alltså upp, ner, inget.
    static func rating(afterTapping tapped: Rating, current: Rating?) -> Rating? {
        current == tapped ? nil : tapped
    }

    /// Var uppspelningen börjar: "Från början" ger 0, annars den sparade positionen (om det finns en att fortsätta
    /// från).
    static func startPosition(progress: WatchProgress?, fromStart: Bool) -> Double? {
        fromStart ? 0 : ProgressPolicy.resumePosition(progress)
    }

    /// Heron som sidan visar: den lästa, annars en byggd av leverantörens titel och affisch (utan backdrop och
    /// logga), så att inget område blir tomt.
    static func displayHero(_ hero: HeroInfo?, item: Library.LibraryItem, container: String?) -> HeroInfo {
        hero ?? AppModel.makeHero(item: item, metadata: nil, container: container, showExternalRatings: false)
    }
}

/// TMDB-uppgifterna och "Liknande titlar" för en detaljsida. De två hämtas i varsin uppgift, så att en hängande
/// metadatabegäran inte fördröjer listan (och tvärtom). Resultaten ligger kvar för sidan: en ny `start` hämtar bara det
/// som inte redan är klart.
@MainActor @Observable
final class TitleExtrasLoader {
    private(set) var detail: TitleDetail?
    private(set) var similar: [Library.LibraryItem] = []
    private(set) var similarLoaded = false
    @ObservationIgnored private var detailLoaded = false
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var similarTask: Task<Void, Never>?

    func start(detail fetchDetail: @escaping @MainActor () async -> TitleDetail?,
               similar fetchSimilar: @escaping @MainActor () async -> [Library.LibraryItem]) {
        if !similarLoaded, similarTask == nil {
            similarTask = Task { [self] in
                let items = await fetchSimilar()
                guard !Task.isCancelled else { return }
                similar = items
                similarLoaded = true
                similarTask = nil
            }
        }
        if !detailLoaded, detailTask == nil {
            detailTask = Task { [self] in
                let found = await fetchDetail()
                guard !Task.isCancelled else { return }
                detail = found
                detailLoaded = true
                detailTask = nil
            }
        }
    }

    /// Avbryter det som pågår (sidan lämnas). Färdiga resultat behålls.
    func cancel() {
        similarTask?.cancel()
        detailTask?.cancel()
        similarTask = nil
        detailTask = nil
    }
}

/// Ett avsnitt som kort i avsnittsraden. Allt är färdigräknat så att korten inte gör något arbete när de ritas.
struct EpisodeCardData: Identifiable, Equatable {
    let id: String
    let season: Int
    /// "4. Avsnittets titel".
    let title: String
    /// Hel längd ("45 min") när den är känd: leverantörens längd först, annars den som sparats vid uppspelning.
    let durationText: String?
    /// Leverantörens stillbild.
    let stillURL: URL?
    /// Beskrivning (visas på högst tre rader).
    let overview: String?
    /// Sedd andel 0...1 för ett påbörjat, ännu inte sett, avsnitt; annars 0.
    let fraction: Double
    let watched: Bool

    /// `info` är TMDB:s uppgifter om avsnittet när de finns: riktig titel, och beskrivning, längd och stillbild som
    /// reserv när leverantören saknar dem (leverantörens egna går först).
    nonisolated static func make(_ episode: Episode, progress: WatchProgress?,
                                 info: TMDBEpisodeInfo? = nil) -> EpisodeCardData {
        var fraction = 0.0
        if let progress, !progress.watched, let duration = progress.duration, duration > 0, progress.position > 0 {
            fraction = min(1, progress.position / duration)
        }
        let known: Double? = episode.durationSeconds.flatMap { $0 > 0 ? Double($0) : nil }
            ?? info?.runtimeMinutes.map { Double($0) * 60 }
            ?? progress?.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let minutes = known.map { max(1, Int(($0 / 60).rounded())) }
        let text = minutes.flatMap { DetailPresentation.remaining(seconds: Double($0) * 60) }
            .map(DetailPresentation.remainingText)
        let providerOverview = episode.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        let overview = providerOverview?.isEmpty == false ? providerOverview : info?.overview
        return EpisodeCardData(id: episode.providerID, season: episode.season,
                               title: displayTitle(episode, info: info),
                               durationText: text,
                               stillURL: episode.stillURL ?? info?.stillPath.map { TMDBImage.url(path: $0, size: .w780) },
                               overview: overview, fraction: fraction, watched: progress?.watched == true)
    }

    /// "4. Avsnittets titel": TMDB:s titel när den finns, annars leverantörens. Heter leverantörens avsnitt bara
    /// "Serie S01E04" (eller "S01E04") visas "Avsnitt 4" i stället, så att serienamnet inte upprepas på varje kort.
    nonisolated static func displayTitle(_ episode: Episode, info: TMDBEpisodeInfo?) -> String {
        if let name = info?.name { return "\(episode.number). \(name)" }
        // Andra frågan fångar en titel som bara är "S01E04" (utan serienamn före).
        if SeriesEpisodeParser.parse(episode.title) != nil || SeriesEpisodeParser.parse("x " + episode.title) != nil {
            return String(localized: "Episode \(episode.number)")
        }
        return "\(episode.number). \(episode.title)"
    }
}
