import Core
import Downloads
import Foundation
import Library
import PlaybackCore

#if !os(tvOS)
/// En titel som passerat sedd-gränsen medan spelaren var öppen.
struct PendingWatchedDownload: Sendable, Equatable {
    var key: ProgressKey
    var profileID: UUID
    /// Position / längd när gränsen passerades.
    var fraction: Double
}

/// Omsluter profilens positionslager och meddelar när en titel går från osedd till sedd. Allt annat skickas
/// vidare oförändrat. Anropas från spelarsessionen på huvudaktören, så `inner.progress` är lika billig som
/// sessionens egen sparning.
final class WatchTransitionUserState: UserStateStore {
    private let inner: any UserStateStore
    private let onBecameWatched: @Sendable (WatchProgress) -> Void

    init(inner: any UserStateStore, onBecameWatched: @escaping @Sendable (WatchProgress) -> Void) {
        self.inner = inner
        self.onBecameWatched = onBecameWatched
    }

    func progress(for key: ProgressKey) -> WatchProgress? { inner.progress(for: key) }

    func save(_ progress: WatchProgress) {
        let wasWatched = inner.progress(for: progress.key)?.watched ?? false
        inner.save(progress)
        if progress.watched, !wasWatched { onBecameWatched(progress) }
    }

    func continueWatching(playlistID: UUID, limit: Int) -> [WatchProgress] {
        inner.continueWatching(playlistID: playlistID, limit: limit)
    }

    func lastWatchedEpisode(playlistID: UUID, seriesProviderID: String) -> WatchProgress? {
        inner.lastWatchedEpisode(playlistID: playlistID, seriesProviderID: seriesProviderID)
    }

    func entries(playlistID: UUID) -> [WatchProgress] { inner.entries(playlistID: playlistID) }
    func remove(playlistID: UUID) { inner.remove(playlistID: playlistID) }
}

/// Automatik för nedladdningar: radera sedda och köa nästa avsnitt. Båda skjuts upp till spelaren stängts,
/// eftersom gränsen normalt passeras medan spelaren är öppen och filen då läses.
extension AppModel {
    /// Positionslagret för spelarsessioner: som `userState`, men meddelar när en titel blir sedd. Utan
    /// nedladdningar (och för barnprofiler) är det `userState` rakt av.
    func watchObservingUserState() -> any UserStateStore {
        guard downloadsAvailable, let profileID = activeProfile?.profile.id else { return userState }
        return WatchTransitionUserState(inner: userState) { [weak self] progress in
            Task { @MainActor in self?.noteBecameWatched(progress, profileID: profileID) }
        }
    }

    func playerDidOpen() { playerIsOpen = true }

    /// Spelaren har stängts (eller försvunnit): nu får uppskjuten automatik köra.
    func playerDidClose() {
        playerIsOpen = false
        guard !pendingWatchedDownloads.isEmpty else { return }
        let previous = watchedProcessingTask
        watchedProcessingTask = Task {
            await previous?.value
            await processWatchedDownloads()
        }
    }

    func noteBecameWatched(_ progress: WatchProgress, profileID: UUID) {
        guard downloadsAvailable, progress.key.kind != .live, activeProfile?.profile.id == profileID else { return }
        let fraction = progress.duration.flatMap { $0 > 0 ? progress.position / $0 : nil } ?? 1
        pendingWatchedDownloads.append(PendingWatchedDownload(key: progress.key, profileID: profileID,
                                                              fraction: fraction))
        // Ingen spelare öppen (t.ex. sen sparning): kör direkt.
        if !playerIsOpen { playerDidClose() }
    }

    /// Hanterar uppskjutna sedda titlar. Rör aldrig något medan spelaren är öppen.
    func processWatchedDownloads() async {
        guard !playerIsOpen else { return }
        let batch = pendingWatchedDownloads
        pendingWatchedDownloads = []
        for entry in batch {
            guard !playerIsOpen, downloadsAvailable, let manager = downloadManager,
                  let active = activeProfile?.profile.id, active == entry.profileID else { continue }
            let settings = currentDownloadSettings
            let key = DownloadKey(profileID: active, playlistID: entry.key.playlistID, kind: entry.key.kind,
                                  providerID: entry.key.providerID)

            if DownloadAutomation.shouldDeleteAfterWatch(settings: settings, watchedFraction: entry.fraction),
               manager.items.first(where: { $0.key == key })?.state == .completed {
                // Samma väg som manuell borttagning: rad, videofil och bilder. Undertexter rörs aldrig.
                await removeDownload(key)
            }
            await fetchNextEpisodeIfWanted(after: entry, settings: settings, manager: manager)
        }
    }

    private func fetchNextEpisodeIfWanted(after entry: PendingWatchedDownload, settings: DownloadSettings,
                                          manager: DownloadManager) async {
        guard entry.key.kind == .series, let series = entry.key.seriesProviderID,
              settings.autoNextEpisode, let network = downloadNetwork else { return }
        let busy = manager.items.contains { item in
            guard item.key.profileID == entry.profileID else { return false }
            switch item.state {
            case .queued, .downloading, .paused: return true
            case .completed, .failed: return false
            }
        }
        // Billig förkontroll innan serien hämtas; regeln nedan avgör.
        guard network.status.isOnWifi, !busy else { return }
        guard let all = try? await episodes(for: series, playlistID: entry.key.playlistID) else { return }
        let existing = Set(manager.items.compactMap { item -> String? in
            guard item.key.profileID == entry.profileID, item.key.playlistID == entry.key.playlistID,
                  item.key.kind == .series else { return nil }
            if case .failed = item.state { return nil }
            return item.key.providerID
        })
        let next = DownloadPlanner.plan(.nextEpisodes(count: 1, after: entry.key.providerID, seriesID: series),
                                        episodes: all, alreadyDownloaded: existing, watched: []).first
        guard DownloadAutomation.nextEpisodeToFetch(settings: settings, onWifi: network.status.isOnWifi,
                                                    hasQueuedOrActive: busy, nextUndownloaded: next) != nil,
              activeProfile?.profile.id == entry.profileID else { return }
        try? await downloadNextEpisodes(count: 1, seriesProviderID: series, after: entry.key.providerID,
                                        playlistID: entry.key.playlistID)
    }

    /// Tar bort profilens nedladdningar (rader och filer) i begärd ordning.
    func scheduleDownloadPurge(profileID: UUID) {
        guard let manager = downloadManager else { return }
        pendingWatchedDownloads.removeAll { $0.profileID == profileID }
        let previous = downloadCleanupTask
        downloadCleanupTask = Task {
            await previous?.value
            await manager.purge(profileID: profileID)
        }
    }
}
#else
extension AppModel {
    func watchObservingUserState() -> any UserStateStore { userState }
    func playerDidOpen() {}
    func playerDidClose() {}
    func scheduleDownloadPurge(profileID: UUID) {}
}
#endif
