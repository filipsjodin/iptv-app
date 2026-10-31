#if !os(tvOS)
import Testing
import UIKit
@testable import IPTVApp

@MainActor
private final class GeometryLog {
    var requests: [UIInterfaceOrientationMask] = []
    var refreshes = 0
}

@MainActor
private func makeController(isPad: Bool, portrait: Bool = false, fail: Bool = false,
                            log: GeometryLog) -> PlayerOrientationController {
    PlayerOrientationController(
        isPad: isPad, deviceIsPortrait: { portrait },
        refreshSupported: { log.refreshes += 1 },
        requestGeometry: { mask, onError in
            log.requests.append(mask)
            if fail { onError(NSError(domain: "test", code: 1)) }
        })
}

@Suite("PlayerOrientation")
struct PlayerOrientationTests {
    @Test func iPhonePlayerIsLandscapeOnly() {
        #expect(PlayerOrientationPolicy.mask(isPlayerPresented: true, isPad: false) == .landscape)
    }

    @Test func iPadPlayerAllowsAllOrientations() {
        #expect(PlayerOrientationPolicy.mask(isPlayerPresented: true, isPad: true) == .all)
    }

    @Test func closedPlayerRestoresPortraitCapableMask() {
        #expect(PlayerOrientationPolicy.mask(isPlayerPresented: false, isPad: false) == .allButUpsideDown)
        #expect(PlayerOrientationPolicy.mask(isPlayerPresented: false, isPad: true) == .all)
    }

    @MainActor
    @Test func controllerRestoresOnCloseEvenIfRequestFails() {
        let log = GeometryLog()
        let c = makeController(isPad: false, portrait: true, fail: true, log: log)
        c.playerWillAppear()
        #expect(c.supportedMask == .landscape)
        c.playerDidClose()
        #expect(c.supportedMask == .allButUpsideDown)
        #expect(!c.isPlayerPresented)
        #expect(log.requests == [.landscape, .portrait])
        #expect(log.refreshes == 2)
    }

    @MainActor
    @Test func closeWithoutAppearIsNoOp() {
        let log = GeometryLog()
        makeController(isPad: false, log: log).playerDidClose()
        #expect(log.requests.isEmpty)
    }
}
#endif
