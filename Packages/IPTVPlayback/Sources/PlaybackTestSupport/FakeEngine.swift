import Foundation
import Playback
import PlaybackCore

/// Registrerar i vilken ordning motorer skapas, laddas och stängs.
@MainActor
public final class EngineRecorder {
    public enum Event: Equatable, Sendable {
        case made(EngineKind)
        case loaded(EngineKind, startAt: Double?)
        case closed(EngineKind)
    }

    public private(set) var events: [Event] = []

    public init() {}

    func record(_ event: Event) { events.append(event) }

    /// Motorer i den ordning de skapades.
    public var kinds: [EngineKind] {
        events.compactMap { if case .made(let k) = $0 { k } else { nil } }
    }

    public func closeCount(_ kind: EngineKind) -> Int {
        events.filter { $0 == .closed(kind) }.count
    }
}

/// Skriptbar motor för tester.
@MainActor
public final class FakeEngine: PlayerEngine {
    public enum Script: Sendable {
        case succeeding(duration: Double?, audio: [MediaTrack], subtitles: [MediaTrack], info: VideoInfo)
        case failing(PlaybackFailure)
        /// `load` hänger (state `.loading`) tills `close()` anropas eller anropande task avbryts,
        /// och kastar då `CancellationError`.
        case hanging

        /// Lyckas med längd 1000 s, inga spår och okänd SDR-video.
        public static func succeeding() -> Script {
            .succeeding(duration: 1000, audio: [], subtitles: [], info: .unknown)
        }
    }

    public let kind: EngineKind
    public var script: Script
    public let recorder: EngineRecorder?

    public private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var currentTime: Double = 0
    public private(set) var duration: Double?
    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []
    public private(set) var selectedAudioID: String?
    public private(set) var selectedSubtitleID: String?
    public private(set) var videoInfo: VideoInfo = .unknown
    public var onStateChange: ((PlaybackState) -> Void)?

    public private(set) var loadedURL: URL?
    public private(set) var loadedStartAt: Double?
    public private(set) var closeCount = 0
    /// Alla anrop till `select(subtitleID:)` i ordning (nil = av).
    public private(set) var subtitleSelections: [String?] = []
    private var hangingLoad: CheckedContinuation<Void, any Error>?

    public init(kind: EngineKind, script: Script, recorder: EngineRecorder? = nil) {
        self.kind = kind
        self.script = script
        self.recorder = recorder
        recorder?.record(.made(kind))
    }

    public func load(url: URL, startAt: Double?) async throws {
        loadedURL = url
        loadedStartAt = startAt
        recorder?.record(.loaded(kind, startAt: startAt))
        state = .loading
        switch script {
        case .hanging:
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        c.resume(throwing: CancellationError())
                    } else {
                        hangingLoad = c
                    }
                }
            } onCancel: {
                Task { @MainActor in self.cancelHangingLoad() }
            }
        case .failing(let failure):
            state = .failed(failure)
            throw failure
        case .succeeding(let duration, let audio, let subtitles, let info):
            self.duration = duration
            audioTracks = audio
            subtitleTracks = subtitles
            videoInfo = info
            currentTime = startAt ?? 0
            state = .playing
        }
    }

    public func play() { state = .playing }
    public func pause() { state = .paused }
    public func seek(to seconds: Double) async { currentTime = seconds }
    public func select(audioID: String?) { selectedAudioID = audioID }
    public func select(subtitleID: String?) {
        selectedSubtitleID = subtitleID
        subtitleSelections.append(subtitleID)
    }

    /// Simulerar att motorn själv byter state (t.ex. fel mitt i strömmen eller slut).
    public func emit(_ newState: PlaybackState) { state = newState }

    private func cancelHangingLoad() {
        hangingLoad?.resume(throwing: CancellationError())
        hangingLoad = nil
    }

    public func close() {
        hangingLoad?.resume(throwing: CancellationError())
        hangingLoad = nil
        closeCount += 1
        recorder?.record(.closed(kind))
        state = .idle
    }
}
