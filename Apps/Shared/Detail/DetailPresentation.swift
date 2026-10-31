import Core
import Foundation
import Library
import Observation
import Personal
import PlaybackCore

/// Rena hjälpfunktioner för detaljsidan (inga vyer, inget nät), så att de kan testas direkt.
enum DetailPresentation {
    /// Återstående tid i heltal: minuter under en timme, annars timmar och minuter.
    enum Remaining: Equatable {
        case minutes(Int)
        case hoursMinutes(Int, Int)
    }

    /// Återstående tid för `seconds`, avrundad uppåt till hela minuter. `nil` när inget återstår eller värdet inte är
    /// ett ändligt tal.
    static func remaining(seconds: Double) -> Remaining? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes >= 60 ? .hoursMinutes(minutes / 60, minutes % 60) : .minutes(minutes)
    }

    /// "32 min", "1 h 5 min" eller "1 h" i användarens språk.
    static func remainingText(_ remaining: Remaining) -> String {
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
    /// Hel längd ("45 min") när den är känd (ur den sparade positionen).
    let durationText: String?
    /// Sedd andel 0...1 för ett påbörjat, ännu inte sett, avsnitt; annars 0.
    let fraction: Double
    let watched: Bool

    static func make(_ episode: Episode, progress: WatchProgress?) -> EpisodeCardData {
        var fraction = 0.0
        if let progress, !progress.watched, let duration = progress.duration, duration > 0, progress.position > 0 {
            fraction = min(1, progress.position / duration)
        }
        let duration = progress?.duration.flatMap { $0.isFinite && $0 > 0 ? max(1, Int(($0 / 60).rounded())) : nil }
        let text = duration.flatMap { DetailPresentation.remaining(seconds: Double($0) * 60) }
            .map(DetailPresentation.remainingText)
        return EpisodeCardData(id: episode.providerID, season: episode.season,
                               title: "\(episode.number). \(episode.title)",
                               durationText: text, fraction: fraction,
                               watched: progress?.watched == true)
    }
}
