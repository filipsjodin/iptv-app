#if !os(tvOS)
import Foundation
import Observation
import Providers

/// Appens offlineläge (iOS/iPadOS). Bygger på `NetworkPolicy` (samma övervakning som nedladdningarna, ingen egen
/// `NWPathMonitor`): offline betyder att nätvägen inte är tillgänglig, aldrig att en förfrågan misslyckats.
///
/// Hysteres: offline utlyses först när nätet varit borta i `offlineDelay` (3 s) i följd, så att korta bortfall
/// (hiss, byte mellan wifi och mobildata) inte får bannern att blinka. Tillbaka online gäller direkt.
@MainActor @Observable
final class OfflineState {
    private(set) var isOffline = false
    /// Antal nätlägen som behandlats (för tester som väntar in en händelse).
    @ObservationIgnored private(set) var statusUpdates = 0

    @ObservationIgnored private let offlineDelay: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var pendingOffline: Task<Void, Never>?

    /// `sleep` kan bytas ut så att tester styr tiden utan att vänta på riktigt.
    init(network: any NetworkPolicy, offlineDelay: Duration = .seconds(3),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.offlineDelay = offlineDelay
        self.sleep = sleep
        let changes = network.changes
        // Lyssnaren avslutas när strömmen tar slut eller när modellen är borta vid nästa händelse.
        Task { [weak self] in
            for await status in changes {
                guard let self else { return }
                self.apply(status)
            }
        }
    }

    private func apply(_ status: NetworkStatus) {
        defer { statusUpdates += 1 }
        if status.isOnline {
            pendingOffline?.cancel()
            pendingOffline = nil
            isOffline = false
            return
        }
        guard !isOffline, pendingOffline == nil else { return }
        let delay = offlineDelay, sleep = sleep
        pendingOffline = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pendingOffline = nil
            self.isOffline = true
        }
    }

    /// Är felet av nätverkstyp (ingen kontakt med servern)? Bara sådana tystas i offlineläge.
    static func isNetworkError(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let providerError = error as? ProviderError, providerError == .unreachable { return true }
        return false
    }

    /// Ska felet döljas som felmeddelande? Sant bara i offlineläge och bara för nätverksfel; övriga fel visas.
    func suppresses(_ error: Error) -> Bool {
        isOffline && Self.isNetworkError(error)
    }
}
#endif
