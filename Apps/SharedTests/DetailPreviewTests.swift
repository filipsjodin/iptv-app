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

    @Test func previewButtonOnlyOnHandheldWhenAllowed() {
        #expect(DetailPreviewGate.showsPreviewButton(previewsEnabled: true, kids: false, platform: .handheld))
        #expect(!DetailPreviewGate.showsPreviewButton(previewsEnabled: false, kids: false, platform: .handheld))
        #expect(!DetailPreviewGate.showsPreviewButton(previewsEnabled: true, kids: true, platform: .handheld))
        #expect(!DetailPreviewGate.showsPreviewButton(previewsEnabled: true, kids: false, platform: .tv))
    }
}
