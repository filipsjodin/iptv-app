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

        let startAt = pendingStartPosition()
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
                // Ersatt av stop()/ny start, eller värd-tasken avbröts: ingen reservmotor, inget fel.
                cancelled(gen)
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
    ///
    /// Fungerar även när uppspelningen har misslyckats (t.ex. "Prova VLC" från felvyn); då laddas målmotorn
    /// från startpositionen (`request.startAt` eller sparad position) med spårpreferenserna.
    public func switchEngine(to kind: EngineKind) async {
        let hasFailed: Bool
        if case .failed = state { hasFailed = true } else { hasFailed = false }
        if let old = engine {
            guard old.kind != kind || hasFailed else { return }
        } else {
            guard hasFailed else { return }
        }
        generation &+= 1
        let gen = generation

        let url: URL
        do {
            url = try request.locator.resolve(with: secret)
        } catch {
            // Pågående uppspelning (om någon) lämnas orörd.
            errorMessageKey = Self.messageKey(for: .unknown)
            return
        }

        // Spår och position tas bara från en motor som har laddat klart; annars gäller startpositionen.
        var position = pendingStartPosition()
        var carried: (audio: MediaTrack?, subtitle: MediaTrack?, subtitleOff: Bool)?
        if let old = engine, lastSave != nil {
            if !request.isLive, old.currentTime.isFinite, old.currentTime > 0 { position = old.currentTime }
            carried = (old.audioTracks.first { $0.id == old.selectedAudioID },
                       old.subtitleTracks.first { $0.id == old.selectedSubtitleID },
                       old.selectedSubtitleID == nil)
            saveProgress()
        }
        if request.isLive { position = nil }
        closeEngine()
        state = .loading

        let e = attachNewEngine(kind)
        do {
            try await e.load(url: url, startAt: position)
            guard gen == generation else { return }
            if let carried {
                if let match = TrackSelector.matching(carried.audio, in: e.audioTracks) { e.select(audioID: match.id) }
                if carried.subtitleOff {
                    e.select(subtitleID: nil)
                } else if let match = TrackSelector.matching(carried.subtitle, in: e.subtitleTracks) {
                    e.select(subtitleID: match.id)
                }
            } else {
                applyPreferredTracks(on: e)
            }
            errorMessageKey = nil
            didLoad(e)
        } catch is CancellationError {
            cancelled(gen)
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

    /// Sparar positionen direkt utan att pausa (t.ex. när appen blir inaktiv under bild-i-bild eller AirPlay).
    /// Nästa periodiska sparning räknas från nu.
    public func saveNow() {
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
    ///
    /// Beräknas från motorns `currentTime`/`duration`, som inte observeras: värdvyn måste läsa om värdet
    /// vid varje `tick()`.
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
            self.engineDidChangeState(newState)
        }
        engine = e
        return e
    }

    /// Reagerar på motorns state efter klar laddning (fel under laddning hanteras i `start()`/`switchEngine`).
    /// Ett fel mitt i strömmen ger ingen automatisk reservmotor; reserv sker bara vid start (spec §7.1).
    /// Användaren kan byta motor manuellt från felvyn.
    private func engineDidChangeState(_ newState: PlaybackState) {
        guard lastSave != nil else { return }
        switch newState {
        case .failed(let failure):
            saveProgress()
            errorMessageKey = Self.messageKey(for: failure)
        case .ended:
            saveProgress()
        default:
            break
        }
    }

    /// Laddningen kastade `CancellationError`. Är den fortfarande aktuell (värd-tasken avbröts) stängs motorn
    /// så att den enda anslutningen frigörs; ingen reserv och inget fel.
    private func cancelled(_ gen: Int) {
        guard gen == generation else { return }
        closeEngine()
        state = .idle
    }

    private func pendingStartPosition() -> Double? {
        request.startAt
            ?? (request.isLive ? nil : ProgressPolicy.resumePosition(userState.progress(for: request.key)))
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
        lastSave = nil
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
