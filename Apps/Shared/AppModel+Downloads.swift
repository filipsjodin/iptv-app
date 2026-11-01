import Core
import Downloads
import Foundation
import Library
import Playback
import PlaybackCore

/// Fasta fel för offlineuppspelning. Aldrig sökväg, URL eller servertext.
enum OfflinePlaybackError: Error, Sendable, Equatable {
    /// Raden är inte färdig, saknar fil eller filen finns inte längre på disken.
    case fileMissing
}

/// Var nästa-avsnitt-leverantören befinner sig.
@MainActor
private final class OfflineEpisodeCursor {
    var providerID: String
    init(providerID: String) { self.providerID = providerID }
}

/// Offlineuppspelning av nedladdade titlar. Går aldrig via `playbackRequest` (katalograden kan vara borta), så
/// barnprofilens kontroll görs om här, och ingen hemlighet eller anslutningsplats behövs.
extension AppModel {
    /// `ProgressKey` som online-uppspelningen använder för samma titel, så att positionen delas.
    nonisolated static func offlineProgressKey(for download: StoredDownload) -> ProgressKey {
        ProgressKey(playlistID: download.key.playlistID, kind: download.key.kind,
                    providerID: download.key.providerID,
                    seriesProviderID: download.key.kind == .series ? download.snapshot.seriesProviderID : nil)
    }

    /// Uppspelningsbegäran för en färdig nedladdning.
    ///
    /// - Throws: `PlaybackLookupError.notAllowed` om nedladdningen inte tillhör den aktiva profilen, eller om den
    ///   aktiva profilen är en barnprofil och titeln inte har en känd, godkänd åldersgräns (stängt som standard,
    ///   även om raden finns kvar eller en annan profil laddat ner den). `OfflinePlaybackError.fileMissing` om
    ///   filen inte finns.
    func offlineRequest(for download: StoredDownload) async throws -> PlaybackRequest {
        guard let active = activeProfile, active.profile.id == download.key.profileID,
              download.key.kind != .live else { throw PlaybackLookupError.notAllowed }
        let progressKey = Self.offlineProgressKey(for: download)
        if active.profile.isKids {
            let discovery = discovery
            let allowed = (try? await offMain { Self.allowedForKids(discovery, key: progressKey) }) ?? false
            guard allowed else { throw PlaybackLookupError.notAllowed }
        }
        guard download.state == .completed, let fileURL = download.fileURL,
              await Self.fileExists(fileURL) else { throw OfflinePlaybackError.fileMissing }

        let title: String
        if download.key.kind == .series, let season = download.snapshot.season, let number = download.snapshot.episode {
            let label = "S\(season):E\(number)"
            title = download.snapshot.seriesTitle.map { "\($0) · \(label)" } ?? "\(label) \(download.snapshot.title)"
        } else {
            title = download.snapshot.title
        }
        return PlaybackRequest(key: progressKey, title: title, locator: download.snapshot.locator,
                               container: OfflinePlayback.container(forFileExtension: fileURL.pathExtension),
                               isLive: false,
                               startAt: DetailPresentation.startPosition(progress: userState.progress(for: progressKey),
                                                                         fromStart: false),
                               localURL: fileURL)
    }

    /// Nästa färdiga nedladdade avsnitt i samma serie (säsong, avsnitt), eller `nil`. Avsnitt som inte är
    /// nedladdade hoppas över. Bara för serieavsnitt; filmer ger `nil`. Nästa avsnitt startar från sparad position.
    func offlineNextEpisodeProvider(for request: PlaybackRequest) -> (@MainActor () async -> PlaybackRequest?)? {
        guard request.localURL != nil, request.key.kind == .series,
              let seriesID = request.key.seriesProviderID, let profileID = activeProfile?.profile.id else { return nil }
        let playlistID = request.key.playlistID
        let cursor = OfflineEpisodeCursor(providerID: request.key.providerID)
        return { [weak self] in
            guard let self, let store = self.downloadStore,
                  let all = try? await offMain({ try store.list(profileID: profileID, playlistID: playlistID) })
            else { return nil }
            let episodes = all.filter {
                $0.key.kind == .series && $0.state == .completed && $0.snapshot.seriesProviderID == seriesID
                    && $0.fileURL != nil
            }
            let available = episodes.compactMap { d -> OfflineEpisode? in
                guard let season = d.snapshot.season, let number = d.snapshot.episode else { return nil }
                return OfflineEpisode(providerID: d.key.providerID, season: season, number: number)
            }
            // Pröva kandidaterna i ordning tills en har en fil på disken och klarar kontrollen.
            for next in OfflinePlayback.following(cursor.providerID, in: available) {
                guard let download = episodes.first(where: { $0.key.providerID == next.providerID }),
                      var nextRequest = try? await self.offlineRequest(for: download) else { continue }
                nextRequest.startAt = nil
                cursor.providerID = next.providerID
                return nextRequest
            }
            return nil
        }
    }

    nonisolated private static func fileExists(_ url: URL) async -> Bool {
        let path = url.path
        return (try? await offMain { FileManager.default.fileExists(atPath: path) }) ?? false
    }
}
