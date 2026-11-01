import Testing
import PlaybackCore
@testable import Downloads

struct OfflinePlaybackLogicTests {
    private func ep(_ id: String, _ s: Int, _ n: Int) -> OfflineEpisode { OfflineEpisode(providerID: id, season: s, number: n) }

    @Test func skipsNotDownloadedAndCrossesSeasons() {
        // S1E2 och S2E1 är nedladdade, S1E3 saknas.
        let available = [ep("a", 1, 1), ep("b", 1, 2), ep("d", 2, 1)]
        #expect(OfflinePlayback.nextEpisode(after: "b", in: available)?.providerID == "d")
        #expect(OfflinePlayback.nextEpisode(after: "a", in: available)?.providerID == "b")
    }

    @Test func nilAtEndOrUnknownCurrent() {
        let available = [ep("a", 1, 1), ep("b", 1, 2)]
        #expect(OfflinePlayback.nextEpisode(after: "b", in: available) == nil)
        #expect(OfflinePlayback.nextEpisode(after: "zzz", in: available) == nil)
    }

    @Test func containerFromExtension() {
        #expect(OfflinePlayback.container(forFileExtension: "MKV") == "mkv")
        #expect(OfflinePlayback.container(forFileExtension: "") == nil)
    }
}

struct OfflineEngineChoiceTests {
    @Test func extensionDrivesEngineSelector() {
        let mkv = OfflinePlayback.container(forFileExtension: "mkv")
        let mp4 = OfflinePlayback.container(forFileExtension: "MP4")
        #expect(EngineSelector.initial(container: mkv, isLive: false, preference: .automatic) == .vlc)
        #expect(EngineSelector.initial(container: mp4, isLive: false, preference: .automatic) == .avPlayer)
    }

    @Test func followingIsOrderedAndSkipsMissing() {
        let all = [OfflineEpisode(providerID: "c", season: 2, number: 1), OfflineEpisode(providerID: "a", season: 1, number: 1),
                   OfflineEpisode(providerID: "b", season: 1, number: 4)]
        #expect(OfflinePlayback.following("a", in: all).map(\.providerID) == ["b", "c"])
    }
}
