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
    /// Serien hade ett färdigt nedladdat avsnitt när titeln blev sedd (även om filen sedan raderats).
    var hadDownload = false
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
        syncCoordinator?.requestImmediatePush()
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
        var hadDownload = false
        if let series = progress.key.seriesProviderID, let manager = downloadManager {
            hadDownload = hasCompletedDownload(series: series, playlistID: progress.key.playlistID,
                                               profileID: profileID, manager: manager)
        }
        pendingWatchedDownloads.append(PendingWatchedDownload(key: progress.key, profileID: profileID,
                                                              fraction: fraction, hadDownload: hadDownload))
        // Ingen spelare öppen (t.ex. sen sparning): kör direkt.
        if !playerIsOpen { playerDidClose() }
    }

    /// Hanterar uppskjutna sedda titlar, en i taget: en post tas först ur listan när den ska bearbetas, så att
    /// ingen försvinner om spelaren öppnas igen eller något annat avbryter. Rör aldrig något medan spelaren är öppen.
    func processWatchedDownloads() async {
        while !playerIsOpen, !pendingWatchedDownloads.isEmpty {
            let entry = pendingWatchedDownloads.removeFirst()
            guard downloadsAvailable, let manager = downloadManager,
                  let active = activeProfile?.profile.id, active == entry.profileID else { continue }
            let settings = currentDownloadSettings
            let key = DownloadKey(profileID: active, playlistID: entry.key.playlistID, kind: entry.key.kind,
                                  providerID: entry.key.providerID)
            // Räknas före raderingen: det sedda avsnittet är det nedladdade avsnittet som ligger till grund.
            let seriesHadDownload = entry.hadDownload || (entry.key.seriesProviderID.map {
                hasCompletedDownload(series: $0, playlistID: entry.key.playlistID, profileID: active,
                                     manager: manager)
            } ?? false)

            if DownloadAutomation.shouldDeleteAfterWatch(settings: settings, watchedFraction: entry.fraction),
               manager.items.first(where: { $0.key == key })?.state == .completed {
                // Samma väg som manuell borttagning: rad, videofil och bilder. Undertexter rörs aldrig.
                await removeDownload(key)
            }
            guard entry.key.kind == .series, let series = entry.key.seriesProviderID, seriesHadDownload else {
                continue
            }
            let deferred = await fetchNextEpisodeIfWanted(
                profileID: active, playlistID: entry.key.playlistID, series: series, after: entry.key.providerID,
                settings: settings, manager: manager)
            if deferred {
                var again = entry
                again.hadDownload = true
                pendingWatchedDownloads.insert(again, at: 0)
            }
        }
    }

    private func hasCompletedDownload(series: String, playlistID: UUID, profileID: UUID,
                                      manager: DownloadManager) -> Bool {
        manager.items.contains {
            $0.key.profileID == profileID && $0.key.playlistID == playlistID && $0.key.kind == .series
                && $0.snapshot.seriesProviderID == series && $0.state == .completed
        }
    }

    /// Köar nästa avsnitt (via wifi, aldrig mobil) om reglerna tillåter. Sant om spelaren öppnades under väntan
    /// och posten därför ska göras om senare.
    private func fetchNextEpisodeIfWanted(profileID: UUID, playlistID: UUID, series: String, after: String?,
                                          settings: DownloadSettings, manager: DownloadManager) async -> Bool {
        guard settings.autoNextEpisode, let network = downloadNetwork else { return false }
        // Single-flight: start, inställningsändring och nätbyte kan komma samtidigt; bara en kontroll köar.
        guard !autoNextInFlight else { return false }
        autoNextInFlight = true
        defer { autoNextInFlight = false }
        // Räknas om efter varje väntan, så att ett avsnitt som köats under tiden syns.
        func isBusy() -> Bool {
            manager.items.contains { item in
                guard item.key.profileID == profileID else { return false }
                switch item.state {
                case .queued, .downloading, .paused: return true
                case .completed, .failed: return false
                }
            }
        }
        // Billig förkontroll innan serien hämtas; regeln nedan avgör.
        guard network.status.isOnWifi, !isBusy() else { return false }
        guard let all = try? await episodes(for: series, playlistID: playlistID) else { return false }
        if playerIsOpen { return true }
        let existing = Set(manager.items.compactMap { item -> String? in
            guard item.key.profileID == profileID, item.key.playlistID == playlistID,
                  item.key.kind == .series else { return nil }
            if case .failed = item.state { return nil }
            return item.key.providerID
        })
        var watched = Set<String>()
        for entry in userState.entries(playlistID: playlistID)
        where entry.key.kind == .series && entry.key.seriesProviderID == series && entry.watched {
            watched.insert(entry.key.providerID)
        }
        let next = DownloadPlanner.plan(.nextEpisodes(count: 1, after: after, seriesID: series),
                                        episodes: all, alreadyDownloaded: existing, watched: watched).first
        guard DownloadAutomation.nextEpisodeToFetch(settings: settings, onWifi: network.status.isOnWifi,
                                                    hasQueuedOrActive: isBusy(), nextUndownloaded: next) != nil,
              activeProfile?.profile.id == profileID else { return false }
        try? await downloadNextEpisodes(count: 1, seriesProviderID: series, after: after, playlistID: playlistID,
                                        requiresWifi: true)
        return false
    }

    /// Nytt försök vid appstart, profilbyte, inställningsändring och när nätet blir wifi: har en serie nedladdade
    /// avsnitt men inget osett kvar (färre än 1) köas nästa avsnitt. Ett avsnitt åt gången.
    func checkAutoNextEpisodes() async {
        guard !playerIsOpen, downloadsAvailable, let manager = downloadManager,
              let profileID = activeProfile?.profile.id else { return }
        let settings = currentDownloadSettings
        guard settings.autoNextEpisode else { return }
        struct SeriesRef: Hashable { var playlistID: UUID; var series: String }
        var unwatched: [SeriesRef: Int] = [:]
        for item in manager.items where item.key.profileID == profileID && item.key.kind == .series
            && item.state == .completed {
            guard let series = item.snapshot.seriesProviderID else { continue }
            let progressKey = Self.offlineProgressKey(for: item)
            let ref = SeriesRef(playlistID: item.key.playlistID, series: series)
            unwatched[ref, default: 0] += userState.progress(for: progressKey)?.watched == true ? 0 : 1
        }
        for (ref, count) in unwatched.sorted(by: { $0.key.series < $1.key.series }) where count < 1 {
            _ = await fetchNextEpisodeIfWanted(profileID: profileID, playlistID: ref.playlistID, series: ref.series,
                                               after: nil, settings: settings, manager: manager)
        }
    }

    /// Appstart: tar bort nedladdningar för profiler som inte längre finns. Gäller bara rader i kända spellistor
    /// (övriga städas av databasens cascade och `purgeOrphans`); inget görs om profillistan ser tom ut.
    func purgeDownloadsOfRemovedProfiles() async {
        guard !usesFallbackDatabase, let manager = downloadManager, !playlists.isEmpty else { return }
        await downloadConfigTask?.value
        let known = Set(playlists.map { $0.id })
        let keep = Set(playlists.flatMap { playlist in profileStore.profiles(playlistID: playlist.id).map { $0.id } })
        guard !keep.isEmpty else { return }
        let removed = Set(manager.items
            .filter { known.contains($0.key.playlistID) && !keep.contains($0.key.profileID) }
            .map { $0.key.profileID })
        for id in removed { await manager.purge(profileID: id) }
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
    func playerDidClose() { syncCoordinator?.requestImmediatePush() }
    func scheduleDownloadPurge(profileID: UUID) {}
    func purgeDownloadsOfRemovedProfiles() async {}
}
#endif
