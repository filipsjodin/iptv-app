import Foundation
import Library
import Observation
import Playback
import Subtitles

/// Det sökmodellen behöver av omvärlden. Closures i stället för `AppModel` direkt, så att fasövergångarna kan
/// testas utan nätverk och databas (appens egen koppling byggs i `init(request:playlistID:app:...)`).
struct SubtitleSearchBackend {
    /// Läser om om uppgifter finns sparade (`refreshOpenSubtitlesStatus`); måste köras innan `isLoggedIn` läses.
    var refreshLogin: @MainActor () async -> Void
    var isLoggedIn: @MainActor () -> Bool
    var search: @MainActor () async throws -> [OpenSubtitlesResult]
    var download: @MainActor (OpenSubtitlesResult) async throws -> (StoredSubtitle, OpenSubtitlesQuota)
    var quota: @MainActor () async -> OpenSubtitlesQuota?
}

/// Tillstånd för sökbladet "Sök fler undertexter…". Ren fasmaskin ovanpå `SubtitleSearchBackend`: inga automatiska
/// omförsök, inga serversvar i felen (bara fasta faser) och ingenting alls i barnläge (då kastar appen
/// `SubtitleAccessError.notAllowed`, vilket blir `.failed(.notAllowed)`).
@MainActor @Observable
final class SubtitleSearchModel {
    enum SubtitleSearchFailure: Equatable {
        case noKey, notAllowed, quota(resetAt: Date?), rateLimited, network
    }

    enum Phase: Equatable {
        case idle, searching, results([OpenSubtitlesResult]), empty, failed(SubtitleSearchFailure)
        /// Nedladdning pågår för resultatet med detta `file_id`.
        case downloading(Int)
        case loginRequired
    }

    private(set) var phase: Phase = .idle
    /// Senast kända dagskvot (efter sökning eller nedladdning).
    private(set) var quota: OpenSubtitlesQuota?

    @ObservationIgnored private let backend: SubtitleSearchBackend
    @ObservationIgnored private let preferredLanguages: [String]
    @ObservationIgnored private let onDownloaded: @MainActor (StoredSubtitle) async -> Void
    /// Senaste träfflistan, så att ett misslyckat nedladdningsförsök kan gå tillbaka till den utan ny sökning.
    @ObservationIgnored private var lastResults: [OpenSubtitlesResult] = []

    /// Träfflistan som visades senast; raderna ligger kvar medan en nedladdning pågår (fasen bär bara id:t).
    var knownResults: [OpenSubtitlesResult] { lastResults }

    init(backend: SubtitleSearchBackend, preferredLanguages: [String],
         onDownloaded: @escaping @MainActor (StoredSubtitle) async -> Void) {
        self.backend = backend
        self.preferredLanguages = preferredLanguages
        self.onDownloaded = onDownloaded
    }

    convenience init(request: PlaybackRequest, playlistID: UUID, app: AppModel, preferredLanguages: [String],
                     onDownloaded: @escaping @MainActor (StoredSubtitle) async -> Void) {
        let backend = SubtitleSearchBackend(
            refreshLogin: { await app.refreshOpenSubtitlesStatus() },
            isLoggedIn: { app.openSubtitlesLoggedIn },
            search: { try await app.searchSubtitles(for: request, playlistID: playlistID, languages: preferredLanguages) },
            download: { try await app.downloadSubtitle($0, for: request, playlistID: playlistID) },
            quota: { await app.openSubtitlesQuota() })
        self.init(backend: backend, preferredLanguages: preferredLanguages, onDownloaded: onDownloaded)
    }

    /// Söker en gång. Körs i anroparens uppgift (`.task` i bladet), så den avbryts när bladet stängs; då lämnas
    /// fasen orörd (aldrig `.searching` för evigt). Ingen automatisk ny sökning efter ett fel.
    func search() async {
        switch phase {
        case .searching, .downloading: return
        default: break
        }
        phase = .searching
        lastResults = []
        await backend.refreshLogin()
        if Task.isCancelled { return resetIfSearching() }
        // Nedladdning kräver konto: utan sparade uppgifter finns ingen anledning att söka.
        guard backend.isLoggedIn() else {
            phase = .loginRequired
            return
        }
        do {
            let found = try await backend.search()
            if Task.isCancelled { return resetIfSearching() }
            let sorted = OpenSubtitlesResult.sorted(found, preferredLanguages: preferredLanguages)
            lastResults = sorted
            phase = sorted.isEmpty ? .empty : .results(sorted)
            // Kvoten är bara till visning; ett fel här ändrar inget.
            let current = await backend.quota()
            if Task.isCancelled { return }
            if let current { quota = current }
        } catch {
            if Task.isCancelled { return resetIfSearching() }
            apply(error)
        }
    }

    /// Laddar ner och lagrar ett resultat och rapporterar den lagrade texten. Bara från träfflistan, en i taget.
    /// Körs oavsett om bladet stängs under tiden (kvoten är redan förbrukad), så att texten inte går förlorad.
    func download(_ result: OpenSubtitlesResult) async {
        guard case .results = phase else { return }
        phase = .downloading(result.id)
        do {
            let (stored, newQuota) = try await backend.download(result)
            quota = newQuota
            phase = .results(lastResults)
            await onDownloaded(stored)
        } catch {
            apply(error)
        }
    }

    /// Tillbaka till träfflistan efter ett misslyckat nedladdningsförsök (utan ny sökning).
    func backToResults() {
        guard !lastResults.isEmpty else { return }
        switch phase {
        case .failed, .loginRequired: phase = .results(lastResults)
        default: break
        }
    }

    /// Bladet stängs: en pågående sökning som inte redan avbrutits av `.task` lämnar `.searching`.
    func cancel() {
        resetIfSearching()
    }

    private func resetIfSearching() {
        if phase == .searching { phase = .idle }
    }

    private func apply(_ error: any Error) {
        guard let next = Self.phase(for: error) else {
            // Avbrott: tillbaka till det som visades före (sökning → idle, nedladdning → träfflistan).
            if case .downloading = phase { phase = .results(lastResults) } else { resetIfSearching() }
            return
        }
        phase = next
    }

    /// Fast fas per fel; aldrig serverns text eller uppgifter. `nil` för avbrott (ingen fasändring).
    static func phase(for error: any Error) -> Phase? {
        if error is CancellationError { return nil }
        switch error {
        case let access as SubtitleAccessError:
            switch access {
            case .notAllowed: return .failed(.notAllowed)
            case .featureDisabled: return .failed(.noKey)
            case .noQuery: return .empty
            }
        case let os as OpenSubtitlesError:
            switch os {
            case .noAPIKey: return .failed(.noKey)
            case .notLoggedIn, .invalidCredentials: return .loginRequired
            case .quotaExhausted(let resetAt): return .failed(.quota(resetAt: resetAt))
            case .rateLimited: return .failed(.rateLimited)
            case .network, .badResponse: return .failed(.network)
            }
        default:
            // Lagringsfel och annat oväntat: ingen detalj visas.
            return .failed(.network)
        }
    }
}
