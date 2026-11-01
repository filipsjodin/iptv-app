#if !os(tvOS)
import Core
import Foundation
import Library
import PlaybackCore

extension AppModel {
    /// Kopplar in nedladdningar: lagret (för offlineuppspelning) och hanteraren, som startas direkt. Hemligheten
    /// hämtas per start via `playbackSecret(for:)`. Tester skickar in en fake-transport och ett fake-nät.
    func attachDownloads(store: DownloadStore, transport: any DownloadTransport, network: any NetworkPolicy,
                         freeSpace: @escaping @Sendable () -> Int64) {
        downloadStore = store
        let manager = DownloadManager(
            store: store, transport: transport, broker: broker, network: network, freeSpace: freeSpace,
            secret: { [weak self] playlistID in
                guard let self else { throw CoreError.missingSecret }
                return try await self.playbackSecret(for: playlistID)
            })
        downloadManager = manager
        Task { await manager.start() }
    }
}
#endif
