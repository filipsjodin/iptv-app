import AVFoundation
import Foundation
import MediaPlayer
import PlaybackCore
import Testing
@testable import IPTVApp

@MainActor
private final class MockCommands: NowPlayingCommands {
    private(set) var pauses = 0
    func play() {}
    func pause() { pauses += 1 }
    func togglePlayPause() {}
    func skip(by seconds: Double) {}
    func seek(to seconds: Double) {}
}

@MainActor
private final class MockSystem: NowPlayingSystem {
    private(set) var info: [String: Any]?
    private(set) var infoWrites = 0
    private(set) var commandsInstalled = false
    private(set) var seekEnabled: Bool?

    func setInfo(_ info: [String: Any]?) {
        self.info = info
        infoWrites += 1
    }
    func installCommands(_ handlers: NowPlayingHandlers) { commandsInstalled = true }
    func removeCommands() { commandsInstalled = false }
    func setSeekCommandsEnabled(_ enabled: Bool) { seekEnabled = enabled }
}

private final class Token {}

@MainActor
private struct Fixture {
    let commands = MockCommands()
    let system = MockSystem()
    let ownership = NowPlayingOwnership()
    let center = NotificationCenter()
    let controller: NowPlayingController

    init() {
        controller = NowPlayingController(commands: commands, system: system, ownership: ownership,
                                          notificationCenter: center)
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
}

private func vod(elapsed: Double = 42, playing: Bool = true) -> NowPlayingInfo {
    NowPlayingInfo(title: "Film", elapsed: elapsed, duration: 7200, isPlaying: playing, isLive: false)
}

@MainActor
@Suite struct NowPlayingControllerTests {
    @Test func stopByNonOwnerDoesNotClear() {
        let f = Fixture()
        let owner = Token(), other = Token()
        f.controller.start(owner: ObjectIdentifier(owner))
        f.controller.update(vod(), owner: ObjectIdentifier(owner))
        f.controller.stop(owner: ObjectIdentifier(other))
        #expect(f.system.info != nil)
        #expect(f.system.commandsInstalled)
        f.controller.stop(owner: ObjectIdentifier(owner))
        #expect(f.system.info == nil)
    }

    @Test func updateByNonOwnerIsIgnored() {
        let f = Fixture()
        let owner = Token(), other = Token()
        f.controller.start(owner: ObjectIdentifier(owner))
        f.controller.update(vod(), owner: ObjectIdentifier(other))
        #expect(f.system.info == nil)
    }

    @Test func commandsAreRemovedOnStop() {
        let f = Fixture()
        let owner = Token()
        f.controller.start(owner: ObjectIdentifier(owner))
        #expect(f.system.commandsInstalled)
        f.controller.stop(owner: ObjectIdentifier(owner))
        #expect(!f.system.commandsInstalled)
    }

    @Test func newOwnerTakesOverAndOldStopDoesNotClear() {
        let ownership = NowPlayingOwnership()
        let systemA = MockSystem(), systemB = MockSystem()
        let a = NowPlayingController(commands: MockCommands(), system: systemA, ownership: ownership,
                                     notificationCenter: NotificationCenter())
        let b = NowPlayingController(commands: MockCommands(), system: systemB, ownership: ownership,
                                     notificationCenter: NotificationCenter())
        let ownerA = Token(), ownerB = Token()
        a.start(owner: ObjectIdentifier(ownerA))
        a.update(vod(), owner: ObjectIdentifier(ownerA))
        b.start(owner: ObjectIdentifier(ownerB))
        #expect(!systemA.commandsInstalled)   // gamla motorns kommandon är borta
        b.update(vod(elapsed: 5), owner: ObjectIdentifier(ownerB))
        a.stop(owner: ObjectIdentifier(ownerA))
        #expect(systemB.info != nil)
        #expect(systemB.commandsInstalled)
    }

    @Test func seekCommandDisabledForLive() {
        let f = Fixture()
        let owner = Token()
        f.controller.start(owner: ObjectIdentifier(owner))
        f.controller.update(NowPlayingInfo(title: "Kanal", elapsed: 10, duration: nil, isPlaying: true, isLive: true),
                            owner: ObjectIdentifier(owner))
        #expect(f.system.seekEnabled == false)
        f.controller.update(vod(), owner: ObjectIdentifier(owner))
        #expect(f.system.seekEnabled == true)
    }

    @Test func interruptionPausesAndKeepsPosition() {
        let f = Fixture()
        let owner = Token()
        f.controller.start(owner: ObjectIdentifier(owner))
        f.controller.update(vod(elapsed: 42), owner: ObjectIdentifier(owner))
        f.controller.interruptionBegan()
        #expect(f.commands.pauses == 1)
        #expect(f.system.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(f.system.info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42)
    }

    @Test func stoppedControllerIgnoresInterruption() {
        let f = Fixture()
        let owner = Token()
        f.controller.start(owner: ObjectIdentifier(owner))
        f.controller.stop(owner: ObjectIdentifier(owner))
        f.controller.interruptionBegan()
        #expect(f.commands.pauses == 0)
    }

    @Test func onlyBeganInterruptionIsRecognized() {
        func note(_ type: AVAudioSession.InterruptionType) -> Notification {
            Notification(name: AVAudioSession.interruptionNotification,
                         userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
        }
        #expect(NowPlayingController.isInterruptionBegan(note(.began)))
        #expect(!NowPlayingController.isInterruptionBegan(note(.ended)))
        #expect(!NowPlayingController.isInterruptionBegan(Notification(name: AVAudioSession.interruptionNotification)))
    }

    @Test func routeChangeOldDeviceUnavailablePauses() {
        let f = Fixture()
        let owner = Token()
        f.controller.start(owner: ObjectIdentifier(owner))
        f.controller.update(vod(elapsed: 30), owner: ObjectIdentifier(owner))
        f.controller.routeBecameUnavailable()
        #expect(f.commands.pauses == 1)
        #expect(f.system.info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(f.system.info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 30)
    }

    @Test func onlyOldDeviceUnavailableRouteChangeIsRecognized() {
        func note(_ reason: AVAudioSession.RouteChangeReason?) -> Notification {
            Notification(name: AVAudioSession.routeChangeNotification,
                         userInfo: reason.map { [AVAudioSessionRouteChangeReasonKey: $0.rawValue] })
        }
        #expect(NowPlayingController.isOldDeviceUnavailable(note(.oldDeviceUnavailable)))
        #expect(!NowPlayingController.isOldDeviceUnavailable(note(.newDeviceAvailable)))
        #expect(!NowPlayingController.isOldDeviceUnavailable(note(.categoryChange)))
        #expect(!NowPlayingController.isOldDeviceUnavailable(note(nil)))
    }

    #if !os(tvOS)
    @Test func notificationsWirePauseAndStopRemovesObservers() async throws {
        let f = Fixture()
        let owner = Token()
        f.controller.start(owner: ObjectIdentifier(owner))
        f.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                      userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await waitUntil { f.commands.pauses == 1 }
        // Annan orsak än urkoppling pausar inte.
        f.center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                      userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        f.center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                      userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        try await waitUntil { f.commands.pauses == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.commands.pauses == 2)
        f.controller.stop(owner: ObjectIdentifier(owner))
        f.center.post(name: AVAudioSession.routeChangeNotification, object: nil,
                      userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        try await Task.sleep(for: .milliseconds(50))
        #expect(f.commands.pauses == 2)
    }

    @Test func systemRemoveCommandsDoesNotDisableSharedCommands() {
        let center = MPRemoteCommandCenter.shared()
        let system = SystemNowPlaying()
        system.installCommands(NowPlayingHandlers(play: {}, pause: {}, toggle: {}, skip: { _ in }, seek: { _ in }))
        // Något annat (t.ex. Apples spelare) har aktiverat kommandona efter bytet.
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        system.removeCommands()
        #expect(center.playCommand.isEnabled)
        #expect(center.pauseCommand.isEnabled)
    }
    #endif

    @Test func infoContainsOnlyTitleTimeAndRate() {
        let dictionary = NowPlayingController.dictionary(for: vod())
        #expect(Set(dictionary.keys) == [MPMediaItemPropertyTitle, MPNowPlayingInfoPropertyElapsedPlaybackTime,
                                         MPNowPlayingInfoPropertyPlaybackRate, MPMediaItemPropertyPlaybackDuration])
        #expect(dictionary[MPMediaItemPropertyTitle] as? String == "Film")
        // Inga URL:er eller andra strängar än titeln.
        let strings = dictionary.values.compactMap { $0 as? String }
        #expect(strings == ["Film"])
        let live = NowPlayingController.dictionary(
            for: NowPlayingInfo(title: "Kanal", elapsed: 1, duration: 99, isPlaying: true, isLive: true))
        #expect(live[MPMediaItemPropertyPlaybackDuration] == nil)
    }
}
