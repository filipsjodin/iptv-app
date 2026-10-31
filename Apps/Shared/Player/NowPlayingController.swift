import AVFoundation
import Foundation
import MediaPlayer
import PlaybackCore

/// Fjärrkommandon som Now Playing-styrningen vidarebefordrar till den aktiva motorn.
@MainActor
protocol NowPlayingCommands: AnyObject {
    func play()
    func pause()
    func togglePlayPause()
    func skip(by seconds: Double)
    func seek(to seconds: Double)
}

/// Hanterare som systemets fjärrkommandon anropar. Closures är `@Sendable` (MPRemoteCommandCenter anropar dem
/// från valfri tråd); varje hanterare hoppar själv till huvudtråden.
struct NowPlayingHandlers: Sendable {
    let play: @Sendable () -> Void
    let pause: @Sendable () -> Void
    let toggle: @Sendable () -> Void
    let skip: @Sendable (Double) -> Void
    let seek: @Sendable (Double) -> Void
}

/// Gränssnittet mot systemet (Kontrollcenter, låsskärm, hörlurar, bilen). Utbytbart i tester.
@MainActor
protocol NowPlayingSystem: AnyObject {
    func setInfo(_ info: [String: Any]?)
    func installCommands(_ handlers: NowPlayingHandlers)
    func removeCommands()
    /// Hopp och positionsändring (bara VOD).
    func setSeekCommandsEnabled(_ enabled: Bool)
}

/// Vem som äger Now Playing just nu. Delas av alla styrningar i appen, så att en värdvy som försvinner efter
/// att nästa motor (motorbyte, nästa avsnitt) tagit över varken rensar eller styr den nya.
@MainActor
final class NowPlayingOwnership {
    static let shared = NowPlayingOwnership()
    private(set) var owner: ObjectIdentifier?
    private(set) weak var active: NowPlayingController?

    func claim(_ owner: ObjectIdentifier, by controller: NowPlayingController) {
        // Den förra styrningen släpper sina kommandon så att inga hanterare pekar på en stoppad motor.
        if let previous = active, previous !== controller { previous.relinquish() }
        self.owner = owner
        active = controller
    }

    func release(_ owner: ObjectIdentifier) -> Bool {
        guard self.owner == owner else { return false }
        self.owner = nil
        active = nil
        return true
    }
}

/// Now Playing och fjärrkommandon för VLC (Apples spelare sköter det själv och rör aldrig den här).
/// Visar bara titel, förfluten tid, längd och hastighet, aldrig URL:er. Bara den aktuella ägaren kan uppdatera
/// eller rensa.
@MainActor
final class NowPlayingController {
    static let skipSeconds = 15.0

    private let commands: any NowPlayingCommands
    private let system: any NowPlayingSystem
    private let ownership: NowPlayingOwnership
    private let notificationCenter: NotificationCenter
    private var lastInfo: NowPlayingInfo?
    private var observers: [NSObjectProtocol] = []
    /// Anropas efter att styrningen själv pausat (avbrott, hörlursurkoppling), så att värden publicerar direkt.
    var onPausedBySystemEvent: (@MainActor () -> Void)?

    init(commands: any NowPlayingCommands,
         system: any NowPlayingSystem = SystemNowPlaying(),
         ownership: NowPlayingOwnership = .shared,
         notificationCenter: NotificationCenter = .default) {
        self.commands = commands
        self.system = system
        self.ownership = ownership
        self.notificationCenter = notificationCenter
    }

    func start(owner: ObjectIdentifier) {
        ownership.claim(owner, by: self)
        system.removeCommands()
        system.installCommands(handlers())
        observeInterruptions()
    }

    func update(_ info: NowPlayingInfo, owner: ObjectIdentifier) {
        guard ownership.owner == owner, ownership.active === self else { return }
        lastInfo = info
        system.setSeekCommandsEnabled(!info.isLive)
        system.setInfo(Self.dictionary(for: info))
    }

    /// Rensar bara om `owner` är den aktuella ägaren.
    func stop(owner: ObjectIdentifier) {
        guard ownership.release(owner) else { return }
        relinquish()
        system.setInfo(nil)
    }

    /// Tar bort kommandon och avbrottsbevakning utan att röra informationen (en ny ägare tar över den).
    fileprivate func relinquish() {
        system.removeCommands()
        removeObservers()
        onPausedBySystemEvent = nil
        lastInfo = nil
    }

    private func removeObservers() {
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    // MARK: - Avbrott

    /// Ett avbrott (samtal, Siri, hörlursurkoppling) pausar och visar pausad med bevarad position. Uppspelningen
    /// återupptas aldrig automatiskt; det är användarens val.
    func interruptionBegan() { pauseForSystemEvent() }

    /// Hörlurar eller annan utgång kopplades ur: pausar på samma sätt som ett avbrott.
    func routeBecameUnavailable() { pauseForSystemEvent() }

    private func pauseForSystemEvent() {
        guard ownership.active === self else { return }
        commands.pause()
        onPausedBySystemEvent?()
        guard let info = lastInfo else { return }
        let paused = NowPlayingInfo(title: info.title, elapsed: info.elapsed, duration: info.duration,
                                    isPlaying: false, isLive: info.isLive)
        lastInfo = paused
        system.setInfo(Self.dictionary(for: paused))
    }

    nonisolated static func isInterruptionBegan(_ notification: Notification) -> Bool {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return false }
        return type == .began
    }

    /// `.oldDeviceUnavailable` (t.ex. hörlurar urkopplade). Läser orsaken defensivt; allt annat ger false.
    nonisolated static func isOldDeviceUnavailable(_ notification: Notification) -> Bool {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return false }
        return reason == .oldDeviceUnavailable
    }

    private func observeInterruptions() {
        #if !os(tvOS)
        removeObservers()
        observers.append(notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard Self.isInterruptionBegan(notification) else { return }
            Task { @MainActor in self?.interruptionBegan() }
        })
        observers.append(notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard Self.isOldDeviceUnavailable(notification) else { return }
            Task { @MainActor in self?.routeBecameUnavailable() }
        })
        #endif
    }

    // MARK: - Kommandon

    private func handlers() -> NowPlayingHandlers {
        NowPlayingHandlers(
            play: { [weak self] in Task { @MainActor in self?.forward { $0.play() } } },
            pause: { [weak self] in Task { @MainActor in self?.forward { $0.pause() } } },
            toggle: { [weak self] in Task { @MainActor in self?.forward { $0.togglePlayPause() } } },
            skip: { [weak self] seconds in Task { @MainActor in self?.forward { $0.skip(by: seconds) } } },
            seek: { [weak self] seconds in Task { @MainActor in self?.forward { $0.seek(to: seconds) } } })
    }

    /// Vidarebefordrar bara medan den här styrningen är den aktiva (aldrig till en stoppad motor).
    private func forward(_ action: (any NowPlayingCommands) -> Void) {
        guard ownership.active === self else { return }
        action(commands)
    }

    // MARK: - Innehåll

    /// Bara titel, förfluten tid, längd (inte live) och hastighet.
    nonisolated static func dictionary(for info: NowPlayingInfo) -> [String: Any] {
        var result: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsedClamped,
            MPNowPlayingInfoPropertyPlaybackRate: info.playbackRate,
        ]
        if let duration = info.durationForDisplay { result[MPMediaItemPropertyPlaybackDuration] = duration }
        return result
    }
}

/// Riktiga `MPNowPlayingInfoCenter` och `MPRemoteCommandCenter`.
@MainActor
final class SystemNowPlaying: NowPlayingSystem {
    private var targets: [(command: MPRemoteCommand, token: Any)] = []

    func setInfo(_ info: [String: Any]?) {
        #if os(tvOS)
        // tvOS visar som förut bara titeln.
        let filtered = info.flatMap { dictionary in
            dictionary[MPMediaItemPropertyTitle].map { [MPMediaItemPropertyTitle: $0] }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = filtered
        #else
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    func installCommands(_ handlers: NowPlayingHandlers) {
        #if !os(tvOS)
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, enabled: Bool = true,
                 _ handler: @escaping @Sendable (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = enabled
            let token = command.addTarget { event in
                handler(event)
                return .success
            }
            targets.append((command, token))
        }
        add(center.playCommand) { _ in handlers.play() }
        add(center.pauseCommand) { _ in handlers.pause() }
        add(center.togglePlayPauseCommand) { _ in handlers.toggle() }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: NowPlayingController.skipSeconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: NowPlayingController.skipSeconds)]
        // Hopp och positionsändring slås på först när en VOD-uppdatering publicerats (live: aldrig).
        add(center.skipForwardCommand, enabled: false) { event in
            let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? NowPlayingController.skipSeconds
            handlers.skip(seconds)
        }
        add(center.skipBackwardCommand, enabled: false) { event in
            let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? NowPlayingController.skipSeconds
            handlers.skip(-seconds)
        }
        add(center.changePlaybackPositionCommand, enabled: false) { event in
            if let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime {
                handlers.seek(position)
            }
        }
        #endif
    }

    /// Tar bara bort de mål som den här instansen lade till. `isEnabled` på de delade kommandona rörs inte, så att
    /// Apples spelare (som kan ha tagit över) inte stängs av; nästa ägare sätter det själv.
    func removeCommands() {
        for (command, token) in targets {
            command.removeTarget(token)
        }
        targets.removeAll()
    }

    func setSeekCommandsEnabled(_ enabled: Bool) {
        #if !os(tvOS)
        guard !targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = enabled
        center.skipBackwardCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled
        #endif
    }
}
