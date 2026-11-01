import Foundation
#if !os(tvOS)
import Core
import Library
import PlaybackCore

extension AppModel {
    /// Kopplar in nedladdningar: lagret (för offlineuppspelning) och hanteraren, som startas direkt. Hemligheten
    /// hämtas per start via `playbackSecret(for:)`. Tester skickar in en fake-transport och ett fake-nät.
    func attachDownloads(store: DownloadStore, transport: any DownloadTransport, network: any NetworkPolicy,
                         freeSpace: @escaping @Sendable () -> Int64) {
        downloadStore = store
        downloadNetwork = network
        DownloadSessionEvents.shared.isTransportAttached = true
        let manager = DownloadManager(
            store: store, transport: transport, broker: broker, network: network, freeSpace: freeSpace,
            secret: { [weak self] playlistID in
                guard let self else { throw CoreError.missingSecret }
                return try await self.playbackSecret(for: playlistID)
            })
        downloadManager = manager
        downloadConfigTask = Task { await manager.start() }
        applyDownloadSettings()
    }

    /// Den aktiva profilens nedladdningsinställningar; standardvärden utan profil och för barnprofiler (där
    /// ingen automatik får köra, oavsett vad som sparats).
    var currentDownloadSettings: DownloadSettings {
        guard !kidsRestricted else { return DownloadSettings() }
        return activeProfile?.settings.downloads ?? DownloadSettings()
    }

    /// Skickar den aktiva profilens nedladdningsinställningar till hanteraren. Anropas när aktiv profil byts
    /// (även till ingen: standardvärden) och när den aktiva profilens inställningar ändras.
    func applyDownloadSettings() {
        guard let manager = downloadManager else { return }
        let settings = currentDownloadSettings
        let previous = downloadConfigTask
        downloadConfigTask = Task {
            await previous?.value
            await manager.configure(settings)
        }
    }

    /// Appen blev aktiv: återsynka nedladdningarna mot systemet.
    func applicationDidBecomeActive() async {
        await downloadManager?.applicationDidBecomeActive()
    }

    /// En uppspelning som använder spellistans anslutning är på väg att starta: pausa våra nedladdningar först.
    func downloadsWillNeedConnection(playlistID: UUID) async {
        await downloadManager?.playbackWillNeedConnection(playlistID: playlistID)
    }
}
#else
extension AppModel {
    func applyDownloadSettings() {}
    func applicationDidBecomeActive() async {}
    func downloadsWillNeedConnection(playlistID: UUID) async {}
}
#endif
