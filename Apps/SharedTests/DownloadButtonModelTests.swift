import Core
import Downloads
import Foundation
import Library
import Personal
import Playback
import PlaybackCore
import Providers
import ProvidersTestSupport
import Testing
@testable import IPTVApp

@MainActor
struct DownloadButtonModelTests {
    @Test func hiddenForKidsAndTvOS() {
        // Kids/tvOS/utan profil ger `available == false`, vilket döljer knappen oavsett tillstånd.
        let states: [DownloadState?] = [nil, .queued, .downloading(progress: 0.5), .paused(.user), .completed,
                                        .failed(.unknown)]
        for state in states {
            #expect(DownloadButtonModel.state(for: state, available: false) == .hidden)
        }
    }

    @Test func stateMappingCoversAllDownloadStates() {
        #expect(DownloadButtonModel.state(for: nil, available: true) == .available)
        #expect(DownloadButtonModel.state(for: .queued, available: true) == .queued)
        #expect(DownloadButtonModel.state(for: .downloading(progress: 0.25), available: true) == .downloading(0.25))
        #expect(DownloadButtonModel.state(for: .downloading(progress: 1.5), available: true) == .downloading(1))
        #expect(DownloadButtonModel.state(for: .downloading(progress: -1), available: true) == .downloading(0))
        for reason in [PauseReason.user, .connectionNeeded, .waitingForWifi, .lowDiskSpace] {
            #expect(DownloadButtonModel.state(for: .paused(reason), available: true) == .paused)
        }
        #expect(DownloadButtonModel.state(for: .completed, available: true) == .completed)
        #expect(DownloadButtonModel.state(for: .failed(.network), available: true) == .failed)
        #expect(DownloadButtonModel.state(for: .failed(.unknown), available: true) == .failed)
    }

    @Test func completedShowsPlayableState() {
        #expect(DownloadButtonModel.state(for: .completed, available: true) == .completed)
        #expect(DownloadButtonModel.state(for: .completed, available: true) != .available)
    }

    @Test func settingsDefaults() {
        let d = DownloadSettings()
        #expect(d.wifiOnly)
        #expect(!d.autoDeleteWatched)
        #expect(!d.autoNextEpisode)
        #expect(PlaybackSettings().downloads == d)
    }

    @Test func settingsTogglesPersistPerProfile() async throws {
        let defaults = freshDefaults()
        let model = AppModel(store: LibraryStore(db: try .inMemory()), credentials: InMemoryCredentialStore(),
                             http: StubHTTPClient(fixtures: standardFixtures), defaults: defaults)
        await model.addPlaylist(name: "Min", secret: xtreamSecret)
        let playlistID = try #require(model.playlists.first?.id)
        model.enter(playlistID: playlistID)
        let first = try #require(model.activeProfile?.profile)
        model.settings.downloads.wifiOnly = false
        model.settings.downloads.autoNextEpisode = true

        let second = try model.addProfile(playlistID: playlistID, name: "Två", avatar: "star.fill")
        try await model.select(profile: second, pin: nil)
        // En annan profil har egna, förvalda inställningar.
        #expect(model.settings.downloads == DownloadSettings())
        model.settings.downloads.autoDeleteWatched = true

        try await model.select(profile: first, pin: nil)
        #expect(model.settings.downloads == DownloadSettings(wifiOnly: false, autoDeleteWatched: false,
                                                             autoNextEpisode: true))
        // Sparat under profilens nyckel: lagringen ger samma värden vid nästa start.
        let loaded = PlaybackSettings.load(from: defaults, key: ProfileKeys.settings(first.id))
        #expect(loaded.downloads == model.settings.downloads)
    }
}
