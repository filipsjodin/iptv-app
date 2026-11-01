import Foundation
import Library
import PlaybackCore
import Testing
@testable import IPTVApp

/// Detaljsidans förhandsvisning (`DetailPreviewGate`): på iPhone/iPad startar inget av sig själv och ingen anslutning
/// tas utan tryck; tvOS är oförändrat. Testverktygen (`Harness`, `movie`) delas med `PreviewControllerTests`.
@MainActor
@Suite struct DetailPreviewTests {
    @Test func iOSDetailDoesNotStartPreviewOnAppear() async {
        let h = Harness()
        DetailPreviewGate.claimOnAppear(h.controller, item: movie("1"), playlistID: h.playlistID, platform: .handheld)
        h.sleeper.advance(by: .seconds(10))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.sleeper.requested.isEmpty)
        #expect(h.resolveCount == 0)
        #expect(h.engines.isEmpty)
        #expect(h.controller.state == .idle)
        #expect(await h.activeLeases() == 0)
    }

    @Test func iOSLoadingStateDoesNotHoldOrStartPreview() async {
        let h = Harness()
        DetailPreviewGate.claimOnAppear(h.controller, item: nil, playlistID: h.playlistID, platform: .handheld)
        #expect(h.sleeper.requested.isEmpty)
        #expect(h.controller.state == .idle)
    }

    @Test func tvDetailStillAutoStartsOnAppear() async {
        let h = Harness()
        let before = h.sleeper.requested.count
        DetailPreviewGate.claimOnAppear(h.controller, item: movie("1"), playlistID: h.playlistID, platform: .tv)
        _ = await eventually { h.sleeper.requested.count > before }
        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.playingEngine() != nil })
    }

    @Test func userTapStartsMutedPreviewAndStopReleasesLease() async {
        let h = Harness()
        h.settings = PlaybackSettings(previewsEnabled: true, previewSoundEnabled: true)
        let started = DetailPreviewGate.userStart(h.controller, item: movie("1"), playlistID: h.playlistID,
                                                  previewsEnabled: true, kids: false, platform: .handheld)
        #expect(started)
        _ = await eventually { h.sleeper.requested.count > 0 }
        h.sleeper.advance(by: .milliseconds(1500))
        #expect(await eventually { h.playingEngine() != nil })
        #expect(h.playingEngine()?.muted == true)
        #expect(await h.activeLeases() == 1)

        // Sidan lämnas eller artworken rullas bort: stoppet är synkront och anslutningen släpps.
        let closing = h.controller.stopNow()
        #expect(h.controller.state == .idle)
        await closing.value
        #expect(await eventually { await h.activeLeases() == 0 })
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func userTapIsRefusedWhenPreviewsAreOffOrProfileIsKids() async {
        let h = Harness()
        let off = DetailPreviewGate.userStart(h.controller, item: movie("1"), playlistID: h.playlistID,
                                              previewsEnabled: false, kids: false, platform: .handheld)
        let kids = DetailPreviewGate.userStart(h.controller, item: movie("1"), playlistID: h.playlistID,
                                               previewsEnabled: true, kids: true, platform: .handheld)
        #expect(!off && !kids)
        #expect(h.sleeper.requested.isEmpty)
        #expect(h.controller.state == .idle)
        #expect(await h.activeLeases() == 0)
    }

    @Test func secondTapAfterFallbackStartsNewAttempt() async {
        let h = Harness()
        h.mode = .fail(.network)
        func tap() async {
            let before = h.sleeper.requested.count
            #expect(DetailPreviewGate.userStart(h.controller, item: movie("1"), playlistID: h.playlistID,
                                                previewsEnabled: true, kids: false, platform: .handheld))
            _ = await eventually { h.sleeper.requested.count > before }
            h.sleeper.advance(by: .milliseconds(1500))
        }
        await tap()
        #expect(await eventually { if case .artwork = h.controller.state { return true } else { return false } })
        h.mode = .succeed
        await tap()
        #expect(await eventually { h.playingEngine() != nil })
        #expect(h.engines.count == 2)
        #expect(await h.connections.acquired.count == 2)
        _ = await h.controller.stopNow().value
        #expect(await eventually { await h.activeLeases() == 0 })
        #expect(await h.eachReleasedExactlyOnce())
    }

    @Test func tapAfterPlayerClosedStartsAgain() async {
        let h = Harness()
        func tap() async {
            let before = h.sleeper.requested.count
            DetailPreviewGate.userStart(h.controller, item: movie("1"), playlistID: h.playlistID,
                                        previewsEnabled: true, kids: false, platform: .handheld)
            _ = await eventually { h.sleeper.requested.count > before }
            h.sleeper.advance(by: .milliseconds(1500))
        }
        await tap()
        #expect(await eventually { h.playingEngine() != nil })
        // Spelaren startar: sidan stoppar förhandsvisningen (state idle); när spelaren stängs hävdar sidan igen.
        _ = await h.controller.stop()
        DetailPreviewGate.claimOnAppear(h.controller, item: movie("1"), playlistID: h.playlistID, platform: .handheld)
        #expect(h.controller.state == .idle)
        await tap()
        #expect(await eventually { h.playingEngine() != nil })
        #expect(h.engines.count == 2)
    }

    @Test func previewButtonOnlyOnHandheldWhenAllowed() {
        #expect(DetailPreviewGate.showsPreviewButton(previewsEnabled: true, kids: false, platform: .handheld))
        #expect(!DetailPreviewGate.showsPreviewButton(previewsEnabled: false, kids: false, platform: .handheld))
        #expect(!DetailPreviewGate.showsPreviewButton(previewsEnabled: true, kids: true, platform: .handheld))
        #expect(!DetailPreviewGate.showsPreviewButton(previewsEnabled: true, kids: false, platform: .tv))
    }
}
