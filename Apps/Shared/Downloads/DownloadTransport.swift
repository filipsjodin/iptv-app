#if !os(tvOS)
import Core
import Downloads
import Foundation

/// Allt transporten behöver för att starta en överföring. URL:en byggs av transporten ur `locator` och `secret`
/// och lämnar den aldrig; inget i den här typen skrivs ut.
struct DownloadTransportRequest: Sendable {
    var key: DownloadKey
    var locator: StreamLocator
    var secret: PlaylistSecret
    /// Återupptagningsdata från en tidigare paus. `nil` startar om från början.
    var resumeData: Data?
    var allowsCellular: Bool
}

extension DownloadTransportRequest: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "DownloadTransportRequest(<redacted>)" }
    var debugDescription: String { description }
}

/// Identifierar en pågående överföring. `taskID` är bakgrundssessionens task-id.
struct DownloadTaskHandle: Sendable, Hashable {
    var key: DownloadKey
    var taskID: Int
}

enum DownloadTransportEvent: Sendable {
    case progress(DownloadTaskHandle, bytesWritten: Int64, totalBytes: Int64)
    /// Svaret är hämtat och filen ligger redan i transportens egen mellanlagring (systemet raderar
    /// delegatens temporärfil direkt efter anropet). Mottagaren äger filen och ska flytta eller radera den.
    case finished(DownloadTaskHandle, stagedFile: URL, status: Int, contentType: String?)
    /// Fast felvärde; `resumeData` finns när systemet kan återuppta överföringen.
    case failed(DownloadTaskHandle, DownloadFailure, resumeData: Data?)
    /// Systemet har levererat alla köade bakgrundshändelser; appdelegatens completion handler får anropas.
    case backgroundEventsFinished
}

/// Gränssnittet mot själva överföringen. Implementeras av `BackgroundDownloadTransport` i appen och av en
/// fake i testerna.
protocol DownloadTransport: Sendable {
    /// Bygger URL:en ur `locator` + `secret` och startar överföringen. Hemligheten hålls aldrig utanför transporten.
    func start(_ request: DownloadTransportRequest) async throws -> DownloadTaskHandle
    /// Stoppar överföringen och returnerar återupptagningsdata om sådan finns. Inga händelser levereras för
    /// den stoppade överföringen efteråt.
    func pause(_ handle: DownloadTaskHandle) async -> Data?
    /// Avbryter och kastar bort överföringen (ingen återupptagningsdata).
    func cancel(_ handle: DownloadTaskHandle) async
    /// En enda ström; konsumeras av `DownloadManager`.
    var events: AsyncStream<DownloadTransportEvent> { get }
    /// Överföringar som systemet fortsatt sedan förra körningen (och alla som just nu pågår).
    func reattach() async -> [DownloadTaskHandle]
}

/// Systemets completion handler för bakgrundssessionen. Appdelegaten lämnar den hit; den anropas när
/// transporten rapporterat `backgroundEventsFinished`, så att systemet kan ta ögonblicksbild och somna om.
@MainActor
final class DownloadSessionEvents {
    static let shared = DownloadSessionEvents()

    private var handler: (() -> Void)?
    /// Systemet hann rapportera "klart" innan appdelegaten lämnat sin handler.
    private var finishedBeforeHandler = false

    init() {}

    /// Sparar handlern. Har sessionen redan rapporterat klart anropas den direkt; annars väntar den på
    /// `complete()`. En tidigare ännu inte anropad handler anropas först (systemet väntar på den).
    func store(_ completionHandler: @escaping () -> Void) {
        handler?()
        handler = nil
        if finishedBeforeHandler {
            finishedBeforeHandler = false
            completionHandler()
        } else {
            handler = completionHandler
        }
    }

    /// Anropar och glömmer den sparade handlern. Finns ingen ännu minns vi att sessionen blivit klar.
    func complete() {
        guard let pending = handler else {
            finishedBeforeHandler = true
            return
        }
        handler = nil
        pending()
    }

    var hasPendingHandler: Bool { handler != nil }
}
#endif
