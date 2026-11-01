import Core
import Foundation
import Testing
import Playback
import PlaybackCore
import PlaybackTestSupport

private let offlinePlaylistID = UUID()
private let onlineSecret = PlaylistSecret.xtream(server: URL(string: "http://example.com:8080")!, username: "user",
                                                 password: "S3cr3t-PW")

private func offlineRequest(container: String?, localURL: URL?) -> PlaybackRequest {
    PlaybackRequest(key: ProgressKey(playlistID: offlinePlaylistID, kind: .movie, providerID: "42"),
                    title: "Titel", locator: .xtream(kind: .movie, streamID: "42", container: "mkv"),
                    container: container, isLive: false, localURL: localURL)
}

@MainActor
private func offlineSession(_ factory: EngineFactory, request: PlaybackRequest,
                            secret: PlaylistSecret? = nil) -> PlaybackSession {
    PlaybackSession(request: request, secret: secret, settings: PlaybackSettings(), userState: CountingStore(),
                    makeEngine: { factory.make($0) },
                    audioSession: AudioSessionControl(activate: {}, deactivate: {}))
}

@MainActor @Suite struct OfflinePlaybackTests {
    private let file = URL(fileURLWithPath: "/var/mobile/Downloads/media.mkv")

    @Test func localURLShortCircuitsResolveAndNeedsNoSecret() async {
        let f = EngineFactory([.vlc: .succeeding()])
        let s = offlineSession(f, request: offlineRequest(container: "mkv", localURL: file))
        await s.start()
        #expect(s.state == .playing)
        #expect(f.last(.vlc)?.loadedURL == file)
        #expect(s.errorMessageKey == nil)
    }

    @Test func localURLWinsOverSecret() async {
        let f = EngineFactory([.vlc: .succeeding()])
        let s = offlineSession(f, request: offlineRequest(container: "mkv", localURL: file), secret: onlineSecret)
        await s.start()
        #expect(f.last(.vlc)?.loadedURL == file)
    }

    @Test func missingBothLocalURLAndSecretFails() async {
        let f = EngineFactory([:])
        let s = offlineSession(f, request: offlineRequest(container: "mp4", localURL: nil))
        await s.start()
        #expect(s.state == .failed(.unknown))
        #expect(s.errorMessageKey == "playback.error.generic")
        #expect(f.recorder.kinds.isEmpty)
    }

    @Test func mkvPicksVLCAndMp4PicksAVPlayerFromExtension() async {
        let f1 = EngineFactory([.vlc: .succeeding()])
        let s1 = offlineSession(f1, request: offlineRequest(
            container: "mkv", localURL: file))
        await s1.start()
        #expect(f1.recorder.kinds == [.vlc])

        let f2 = EngineFactory([.avPlayer: .succeeding()])
        let mp4 = URL(fileURLWithPath: "/var/mobile/Downloads/media.mp4")
        let s2 = offlineSession(f2, request: offlineRequest(
            container: mp4.pathExtension, localURL: mp4))
        await s2.start()
        #expect(f2.recorder.kinds == [.avPlayer])
    }

    @Test func existingOnlineRequestsUnchanged() async {
        let request = offlineRequest(container: "mp4", localURL: nil)
        #expect(request.localURL == nil)
        let f = EngineFactory([.avPlayer: .succeeding()])
        let s = offlineSession(f, request: request, secret: onlineSecret)
        await s.start()
        let loaded = f.last(.avPlayer)?.loadedURL
        #expect(loaded?.host == "example.com")
        #expect(loaded?.isFileURL == false)
    }

    @Test func reloadAndRetryUseLocalURL() async {
        let f = EngineFactory([.avPlayer: .succeeding(), .vlc: .succeeding()])
        let s = offlineSession(f, request: offlineRequest(container: "mp4", localURL: file))
        await s.start()
        await s.switchEngine(to: .vlc)
        #expect(f.last(.vlc)?.loadedURL == file)
        await s.retry()
        #expect(f.made.count == 3)
        #expect(f.made.allSatisfy { $0.loadedURL == file })
        #expect(s.errorMessageKey == nil)
    }
}
