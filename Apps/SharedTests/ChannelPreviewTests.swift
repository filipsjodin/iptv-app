import Core
import Foundation
import Library
import Playback
import PlaybackCore
import Providers
import Testing
@testable import IPTVApp

private func channel(_ id: String) -> ChannelGroup {
    let stream = LiveStream(providerID: id, name: "Kanal \(id)", categoryID: "1", epgChannelID: nil,
                            locator: .xtream(kind: .live, streamID: id, container: "m3u8"))
    return ChannelGrouper.group([stream])[0]
}

/// Kanalförhandsvisningen i `PreviewController` (`focus(channel:playlistID:)`): samma settle-, ägar- och lease-regler
/// som för titlar. Testverktygen delas med `PreviewControllerTests`.
@MainActor
struct ChannelPreviewTests {
    @Test func focusOnChannelStartsAfterSettleDelay() async {
        let h = Harness()
        let group = channel("1")
        h.controller.focus(channel: group, playlistID: h.playlistID)
        #expect(h.controller.state == .idle)
        #expect(await eventually { h.sleeper.requested == [.milliseconds(1500)] })
        h.sleeper.advance(by: .milliseconds(1499))
        await drain()
        #expect(h.engines.isEmpty)
        #expect(h.channelResolved.isEmpty)
        #expect(await h.activeLeases() == 0)

        h.sleeper.advance(by: .milliseconds(1))
        #expect(await eventually { h.playingEngine() != nil })
        let engine = h.engines.first
        #expect(h.engines.count == 1)
        #expect(h.channelResolved == [group.id])
        // Live: ingen startposition och tyst.
        #expect(engine?.loadedStartAt == nil)
        #expect(engine?.muted == true)
        #expect(await h.activeLeases() == 1)
        await h.controller.stop()
        #expect(await h.activeLeases() == 0)
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func channelPreviewIsAlwaysMuted() async {
        let h = Harness()
        h.settings = PlaybackSettings(previewSoundEnabled: true)
        await h.focus(channel: channel("1"))
        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.playingEngine() != nil })
        let engine = h.engines.first
        #expect(engine?.muted == true)
        h.controller.setSoundEnabled(false)
        h.controller.setSoundEnabled(true)
        #expect(engine?.muted == true)
        await h.controller.stop()
    }

    @Test func titlePreviewSoundStillFollowsProfile() async {
        let h = Harness()
        h.settings = PlaybackSettings(previewSoundEnabled: true)
        await h.focusAndSettle(movie("1"))
        #expect(await eventually { h.playingEngine() != nil })
        #expect(h.engines.first?.muted == false)
        await h.controller.stop()
    }

    @Test func previewNeverEvictsPlayingStream() async {
        let h = Harness()
        await h.broker.setLimit(1, playlistID: h.playlistID)
        let revoked = RevokeFlag()
        let playback = await h.broker.acquire(.playback, playlistID: h.playlistID) { await revoked.set() }
        #expect(playback != nil)

        await h.focus(channel: channel("1"))
        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.controller.state == .artwork(.connectionBusy) })
        #expect(h.engines.isEmpty)
        #expect(await revoked.value == false)
        #expect(await h.activeLeases() == 1)
        await h.controller.stop()
        #expect(await h.activeLeases() == 1)
        if let playback { await h.broker.release(playback) }
        #expect(await h.activeLeases() == 0)
    }

    @Test func playbackRevokesChannelPreview() async {
        let h = Harness()
        await h.broker.setLimit(1, playlistID: h.playlistID)
        await h.focus(channel: channel("1"))
        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.playingEngine() != nil })
        let engine = h.engines.first

        // Uppspelning tar anslutningen: förhandsvisningen stängs först.
        let playback = await h.broker.acquire(.playback, playlistID: h.playlistID) {}
        #expect(playback != nil)
        #expect(engine?.closeFinished == true)
        #expect(h.controller.state == .artwork(.connectionBusy))
        await h.controller.stop()
        if let playback { await h.broker.release(playback) }
        #expect(await h.activeLeases() == 0)
    }

    @Test func kidsProfileNeverStartsChannelPreview() async {
        let h = Harness()
        h.channelAllowed = false
        h.controller.focus(channel: channel("1"), playlistID: h.playlistID)
        #expect(h.controller.state == .artwork(.kidsDenied))
        h.sleeper.advance(by: .seconds(5))
        await drain()
        #expect(h.sleeper.requested.isEmpty)
        #expect(h.channelResolved.isEmpty)
        #expect(h.engines.isEmpty)
        #expect(await h.connections.acquireCalls == 0)
        #expect(await h.activeLeases() == 0)
    }

    @Test func profileTurnedKidsDuringSettleNeverRequestsStream() async {
        let h = Harness()
        await h.focus(channel: channel("1"))
        // Profilbyte under väntan: nekas efter stillastående, ingen ström begärs.
        h.channelAllowed = false
        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.controller.state == .artwork(.kidsDenied) })
        #expect(h.channelResolved.isEmpty)
        #expect(h.engines.isEmpty)
        #expect(await h.connections.acquireCalls == 0)
    }

    @Test func fastFocusMovesStartOnlyLastChannel() async {
        let h = Harness()
        let groups = (0..<10).map { channel("\($0)") }
        await h.focus(channel: groups[0])
        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.playingEngine() != nil })
        #expect(h.engines.count == 1)

        // Nio fokusbyten 50 ms isär: ingen mellankanal hinner bli stillastående, den spelande stängs direkt.
        for group in groups.dropFirst() {
            await h.focus(channel: group)
            #expect(h.controller.state == .idle)
            h.sleeper.advance(by: .milliseconds(50))
        }
        await drain()
        #expect(h.engines.count == 1)
        #expect(h.engines.first?.closeFinished == true)
        #expect(h.channelResolved == [groups[0].id])
        #expect(await h.activeLeases() == 0)

        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.playingEngine() != nil })
        #expect(h.channelResolved == [groups[0].id, groups[9].id])
        #expect(h.engines.count == 2)
        #expect(await h.activeLeases() == 1)
        await h.controller.stop()
        #expect(await h.activeLeases() == 0)
        #expect(await h.connections.acquired.count == 2)
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func sameChannelAgainIsNoOpAndNilFocusStops() async {
        let h = Harness()
        let group = channel("1")
        await h.focus(channel: group)
        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.playingEngine() != nil })
        h.controller.focus(channel: group, playlistID: h.playlistID)
        await drain()
        #expect(h.engines.count == 1)
        #expect(h.controller.isPlaying)

        h.controller.focusChanged(to: nil, playlistID: h.playlistID)
        #expect(h.controller.state == .idle)
        await h.controller.stop()
        #expect(h.engines.first?.closeFinished == true)
        #expect(await h.activeLeases() == 0)
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func channelWithoutStreamFallsBackToArtwork() async {
        let h = Harness()
        h.channelSource = nil
        await h.focus(channel: channel("1"))
        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.controller.state == .artwork(nil) })
        #expect(h.engines.isEmpty)
        #expect(await h.activeLeases() == 0)
    }

    @Test func rawTransportStreamChannelGetsArtworkOnly() async {
        let h = Harness()
        h.channelSource = PreviewSource(url: URL(string: "http://example.invalid/live/u/p/1.ts")!,
                                        containerExtension: "ts", durationHint: nil)
        await h.focus(channel: channel("1"))
        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.controller.state == .artwork(.unsupportedContainer) })
        #expect(await h.connections.acquireCalls == 0)
    }

    @Test func titleFocusStillIgnoresLiveItems() async {
        let h = Harness()
        let live = Library.LibraryItem(kind: .live, providerID: "1", title: "Kanal", year: nil, posterURL: nil)
        h.controller.focusChanged(to: live, playlistID: h.playlistID)
        await drain()
        #expect(h.controller.state == .idle)
        #expect(h.sleeper.requested.isEmpty)
    }
}
