import Core
import Foundation
import Observation
import PlaybackCore

/// Vad som ska spelas. Innehåller aldrig credentials; URL:en löses upp först vid uppspelning.
public struct PlaybackRequest: Sendable {
    public var key: ProgressKey
    public var title: String
    public var locator: StreamLocator
    public var container: String?
    public var isLive: Bool
    /// Uttrycklig startposition; nil betyder återuppta från sparad position (aldrig för live).
    public var startAt: Double?

    public init(key: ProgressKey, title: String, locator: StreamLocator, container: String?, isLive: Bool,
                startAt: Double? = nil) {
        self.key = key
        self.title = title
        self.locator = locator
        self.container = container
        self.isLive = isLive
        self.startAt = startAt
    }
}

/// En uppspelning: motorval, en reservmotor (bara läget automatic), motorbyte, spårval och tittarposition.
///
/// Den upplösta URL:en (med lösenord) hålls bara i lokala variabler och hamnar aldrig i state, fel eller loggar.
@MainActor @Observable
public final class PlaybackSession {
    public private(set) var engine: (any PlayerEngine)?
    public private(set) var state: PlaybackState = .idle
    /// Lokaliseringsnyckel för ett vänligt felmeddelande.
    public private(set) var errorMessageKey: String?

    @ObservationIgnored private let request: PlaybackRequest
    @ObservationIgnored private let secret: PlaylistSecret
    @ObservationIgnored private let settings: PlaybackSettings
    @ObservationIgnored private let userState: any UserStateStore
    @ObservationIgnored private let makeEngine: @MainActor (EngineKind) -> any PlayerEngine
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Ökas vid varje start/byte/stopp så att en ersatt laddning inte skriver över nyare state.
    @ObservationIgnored private var generation = 0
    /// Tidpunkt för senaste sparning; nil tills en motor har laddats klart.
    @ObservationIgnored private var lastSave: Date?

    public init(request: PlaybackRequest, secret: PlaylistSecret, settings: PlaybackSettings,
                userState: any UserStateStore, makeEngine: @escaping @MainActor (EngineKind) -> any PlayerEngine,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.request = request
        self.secret = secret
        self.settings = settings
        self.userState = userState
        self.makeEngine = makeEngine
        self.now = now
    }

    // MARK: - Start och motorbyte

    public func start() async {
        generation &+= 1
        let gen = generation
        errorMessageKey = nil
        closeEngine()
        try? AudioSessionConfigurator.configureForPlayback()
        state = .loading

        let url: URL
        do {
            url = try request.locator.resolve(with: secret)
        } catch {
            fail(with: .unknown)
            return
        }

        let startAt: Double? = request.startAt
            ?? (request.isLive ? nil : ProgressPolicy.resumePosition(userState.progress(for: request.key)))
        var kind = EngineSelector.initial(container: request.container, isLive: request.isLive,
                                          preference: settings.engine)
        var tried: Set<EngineKind> = []

        while true {
            tried.insert(kind)
            let e = attachNewEngine(kind)
            do {
                try await e.load(url: url, startAt: startAt)
                guard gen == generation else { return }
                applyPreferredTracks(on: e)
                didLoad(e)
                return
            } catch is CancellationError {
                // Ersatt av stop()/ny start: ingen reservmotor, inget fel.
                return
            } catch {
                guard gen == generation else { return }
                let failure = (error as? PlaybackFailure) ?? .unknown
                // Stäng före nästa motor öppnas (max_connections == 1).
                closeEngine()
                if let next = EngineSelector.fallback(after: kind, preference: settings.engine, alreadyTried: tried) {
                    kind = next
                    state = .loading
                    continue
                }
                fail(with: failure)
                return
            }
        }
    }

    /// Byter motor manuellt med bevarad position och ljud-/textspråk. Ingen automatisk reserv vid fel.
    public func switchEngine(to kind: EngineKind) async {
        guard let old = engine, old.kind != kind else { return }
        generation &+= 1
        let gen = generation

        let url: URL
        do {
            url = try request.locator.resolve(with: secret)
        } catch {
            errorMessageKey = Self.messageKey(for: .unknown)
            return
        }

        let position: Double? = request.isLive ? nil : old.currentTime
        let audio = old.audioTracks.first { $0.id == old.selectedAudioID }
        let subtitle = old.subtitleTracks.first { $0.id == old.selectedSubtitleID }
        errorMessageKey = nil
        closeEngine()
        state = .loading

        let e = attachNewEngine(kind)
        do {
            try await e.load(url: url, startAt: position)
            guard gen == generation else { return }
            if let match = TrackSelector.matching(audio, in: e.audioTracks) { e.select(audioID: match.id) }
            if let match = TrackSelector.matching(subtitle, in: e.subtitleTracks) { e.select(subtitleID: match.id) }
            didLoad(e)
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation else { return }
            closeEngine()
            fail(with: (error as? PlaybackFailure) ?? .unknown)
        }
    }

    // MARK: - Spår

    public func selectAudio(_ id: String?) { engine?.select(audioID: id) }
    public func selectSubtitle(_ id: String?) { engine?.select(subtitleID: id) }

    // MARK: - Tittarposition

    /// Anropas av värdvyn ungefär varje sekund; sparar positionen var `ProgressPolicy.saveInterval`
    /// räknat från start eller senaste sparning.
    public func tick() {
        guard let last = lastSave else { return }
        let t = now()
        if t.timeIntervalSince(last) >= Self.saveIntervalSeconds {
            saveProgress()
            lastSave = t
        }
    }

    public func pauseAndSave() {
        engine?.pause()
        saveProgress()
        if lastSave != nil { lastSave = now() }
    }

    /// Sparar positionen och stänger motorn. Kan anropas flera gånger.
    public func stop() {
        generation &+= 1
        saveProgress()
        closeEngine()
        lastSave = nil
        state = .idle
    }

    /// True när högst `ProgressPolicy.nextEpisodeLead` sekunder återstår av ett serieavsnitt.
    public var nextEpisodeOffer: Bool {
        guard request.key.kind == .series, let e = engine, let d = e.duration, d.isFinite, d > 0 else { return false }
        return d - e.currentTime <= ProgressPolicy.nextEpisodeLead
    }

    // MARK: - Privat

    private static let saveIntervalSeconds: Double = {
        let c = ProgressPolicy.saveInterval.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }()

    private static func messageKey(for failure: PlaybackFailure) -> String {
        switch failure {
        case .unsupportedFormat: "playback.error.unsupported"
        case .network, .timeout: "playback.error.network"
        case .unknown: "playback.error.generic"
        }
    }

    private func attachNewEngine(_ kind: EngineKind) -> any PlayerEngine {
        let e = makeEngine(kind)
        e.onStateChange = { [weak self, weak e] newState in
            guard let self, let e, self.engine === e else { return }
            self.state = newState
        }
        engine = e
        return e
    }

    private func didLoad(_ e: any PlayerEngine) {
        lastSave = now()
        state = e.state
    }

    private func fail(with failure: PlaybackFailure) {
        errorMessageKey = Self.messageKey(for: failure)
        state = .failed(failure)
    }

    private func closeEngine() {
        guard let e = engine else { return }
        engine = nil
        e.onStateChange = nil
        e.close()
    }

    private func applyPreferredTracks(on e: any PlayerEngine) {
        let choice = TrackSelector.choose(audio: e.audioTracks, subtitles: e.subtitleTracks, prefs: settings.tracks)
        if let audioID = choice.audioID { e.select(audioID: audioID) }
        if !e.subtitleTracks.isEmpty { e.select(subtitleID: choice.subtitleID) }
    }

    private func saveProgress() {
        guard !request.isLive, let e = engine, e.duration != nil,
              let p = ProgressPolicy.progress(key: request.key, position: e.currentTime, duration: e.duration, now: now())
        else { return }
        userState.save(p)
    }
}
