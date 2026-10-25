import Foundation
import Playback
import PlaybackCore
import UIKit
import VLCKit

/// Uppspelning via VLCKit 4 (LGPL-2.1). `drawable` placeras i värdvyn och visar videon.
///
/// Semantiken följer `AVPlayerEngine`: `load` väntar tills strömmen spelar (timeout 15 s → `.timeout`),
/// en ersatt eller stängd laddning kastar `CancellationError`. VLC ger inga detaljerade fel, så ett fel
/// innan strömmen öppnats blir `.network` och ett fel efter det `.unknown`.
/// Loggar aldrig URL:er och lägger aldrig felsträngar i state.
@MainActor
public final class VLCPlayerEngine: PlayerEngine {
    public let kind: EngineKind = .vlc
    /// Vyn som VLC ritar video i. Ägs av motorn och återanvänds mellan laddningar.
    public let drawable: UIView

    public private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((PlaybackState) -> Void)?

    private let loadTimeout: Duration
    /// En ny spelare per laddning, så att sena händelser från en tidigare ström aldrig når den nya.
    private var player: VLCMediaPlayer?
    private var relay: VLCEventRelay?
    private var currentURL: URL?
    /// Ökas vid varje load/close så att en avbruten laddning inte skriver över nyare state.
    private var generation = 0
    private var isActive = false
    private var sawError = false
    private var bufferingProgress: Float = 1
    private var bufferingCompleted = false

    public init(loadTimeout: Duration = .seconds(15)) {
        self.loadTimeout = loadTimeout
        drawable = UIView()
        drawable.backgroundColor = .black
    }

    isolated deinit {
        tearDown()
    }

    // MARK: - Läsning

    public var currentTime: Double {
        guard isActive, let ms = player?.time.value?.doubleValue, ms.isFinite, ms > 0 else { return 0 }
        return ms / 1000
    }

    public var duration: Double? {
        guard isActive, let ms = player?.media?.length.value?.doubleValue, ms.isFinite, ms > 0 else { return nil }
        return ms / 1000
    }

    public var audioTracks: [MediaTrack] {
        guard isActive, let player else { return [] }
        return Self.tracks(player.audioTracks, kind: .audio)
    }

    public var subtitleTracks: [MediaTrack] {
        guard isActive, let player else { return [] }
        return Self.tracks(player.textTracks, kind: .subtitle)
    }

    public var selectedAudioID: String? {
        guard isActive, let player else { return nil }
        return player.audioTracks.firstIndex(where: \.isSelected).map { "\($0)" }
    }

    public var selectedSubtitleID: String? {
        guard isActive, let player else { return nil }
        return player.textTracks.firstIndex(where: \.isSelected).map { "\($0)" }
    }

    /// Upplösning från `videoSize`, codec/bildfrekvens/bitrate från videospåret. VLCKit exponerar ingen
    /// överföringsfunktion, så dynamiskt omfång klassas bara på codec (i praktiken SDR) – bästa försök.
    public var videoInfo: VideoInfo {
        guard isActive, let player else { return .unknown }
        var info = VideoInfo.unknown
        let size = player.videoSize
        if size.width > 0, size.height > 0 {
            info.width = Int(size.width.rounded())
            info.height = Int(size.height.rounded())
        }
        let videoTracks = player.videoTracks
        if let track = videoTracks.first(where: \.isSelected) ?? videoTracks.first {
            let codec = Self.fourCC(track.codec)
            info.videoCodec = codec
            info.dynamicRange = DynamicRange.classify(codecs: codec.map { [$0] } ?? [], transferFunction: nil,
                                                      hasDolbyVisionConfig: false)
            if track.bitrate > 0 { info.bitrate = Double(track.bitrate) }
            if let video = track.video {
                if video.frameRate > 0, video.frameRateDenominator > 0 {
                    info.frameRate = Double(video.frameRate) / Double(video.frameRateDenominator)
                }
                if info.height == nil, video.width > 0, video.height > 0 {
                    info.width = Int(video.width)
                    info.height = Int(video.height)
                }
            }
        }
        let audio = audioTracks
        info.audioDescription = Self.audioDescription(for: selectedAudioID.flatMap { id in audio.first { $0.id == id } })
        return info
    }

    // MARK: - Laddning

    /// Kastar `PlaybackFailure`, eller `CancellationError` om laddningen ersätts av `close()`/ny `load` eller avbryts.
    public func load(url: URL, startAt: Double?) async throws {
        generation += 1
        let gen = generation
        tearDown()
        state = .loading

        do {
            guard let media = VLCMedia(url: url) else { throw PlaybackFailure.unknown }
            if let startAt, startAt > 0 {
                media.addOption(":start-time=\(startAt)")
            }
            let player = VLCMediaPlayer()
            let relay = VLCEventRelay { [weak self] event in
                guard let self else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self.handle(event, generation: gen) }
                } else {
                    Task { @MainActor in self.handle(event, generation: gen) }
                }
            }
            player.delegate = relay
            player.drawable = drawable
            player.media = media
            self.player = player
            self.relay = relay
            currentURL = url
            player.play()

            try await waitUntilPlaying(player, deadline: .now + loadTimeout, generation: gen)
            try checkCurrent(gen)
            isActive = true
            state = .playing
            apply(player.state)
        } catch let failure as PlaybackFailure {
            if gen == generation {
                tearDown()
                state = .failed(failure)
            }
            throw failure
        } catch {
            if gen == generation {
                tearDown()
                state = .idle
            }
            throw error
        }
    }

    private func checkCurrent(_ gen: Int) throws {
        guard gen == generation else { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Klar när spelaren spelar och antingen buffringen är klar, video visas eller tiden har börjat gå.
    private func waitUntilPlaying(_ player: VLCMediaPlayer, deadline: ContinuousClock.Instant, generation gen: Int) async throws {
        var started = false
        var opened = false
        while true {
            try checkCurrent(gen)
            let failure: PlaybackFailure = opened ? .unknown : .network
            if sawError { throw failure }
            switch player.state {
            case .opening:
                started = true
            case .playing, .paused:
                started = true
                opened = true
                let time = player.time.value?.doubleValue ?? 0
                if bufferingCompleted || player.hasVideoOut || time > 0 { return }
            case .error:
                throw failure
            case .stopped, .stopping:
                if started { throw failure }
            case .nothingSpecial:
                break
            @unknown default:
                break
            }
            if ContinuousClock.now >= deadline { throw PlaybackFailure.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Styrning

    public func play() {
        guard isActive, let player else { return }
        if state == .ended {
            restart(at: 0)
            return
        }
        player.play()
        state = .playing
    }

    public func pause() {
        guard isActive, let player else { return }
        player.pause()
        state = .paused
    }

    /// Efter slutet startas strömmen om på den nya positionen, eftersom VLC har stannat spelaren.
    public func seek(to seconds: Double) async {
        guard isActive, let player else { return }
        let target = max(0, seconds)
        if state == .ended {
            restart(at: target)
            return
        }
        player.time = VLCTime(number: NSNumber(value: Int64((target * 1000).rounded())))
    }

    public func select(audioID: String?) {
        guard isActive, let player else { return }
        let tracks = player.audioTracks
        guard let audioID else {
            player.deselectAllAudioTracks()
            return
        }
        guard let index = Int(audioID), tracks.indices.contains(index) else { return }
        tracks[index].isSelectedExclusively = true
    }

    /// `nil` stänger av undertexter.
    public func select(subtitleID: String?) {
        guard isActive, let player else { return }
        let tracks = player.textTracks
        guard let subtitleID else {
            player.deselectAllTextTracks()
            return
        }
        guard let index = Int(subtitleID), tracks.indices.contains(index) else { return }
        tracks[index].isSelectedExclusively = true
    }

    public func close() {
        generation += 1
        tearDown()
        state = .idle
    }

    // MARK: - Händelser

    private func handle(_ event: VLCEventRelay.Event, generation gen: Int) {
        guard gen == generation, let player else { return }
        switch event {
        case .state(let newState):
            if newState == .error { sawError = true }
            apply(newState)
        case .buffering(let progress):
            bufferingProgress = progress
            if progress >= 1 { bufferingCompleted = true }
            apply(player.state)
        }
    }

    private func apply(_ vlcState: VLCMediaPlayerState) {
        guard isActive else { return }
        if case .failed = state { return }
        switch vlcState {
        case .opening:
            state = .buffering
        case .playing:
            state = bufferingProgress < 1 ? .buffering : .playing
        case .paused:
            state = .paused
        case .error:
            state = .failed(.unknown)
        case .stopped, .stopping:
            // VLC 4 har inget eget slut-tillstånd: stopp utan fel efter laddning betyder att strömmen tog slut.
            state = sawError ? .failed(.unknown) : .ended
        case .nothingSpecial:
            break
        @unknown default:
            break
        }
    }

    private func restart(at seconds: Double) {
        guard let player, let url = currentURL, let media = VLCMedia(url: url) else { return }
        if seconds > 0 { media.addOption(":start-time=\(seconds)") }
        player.media = media
        player.play()
        state = .buffering
    }

    private func tearDown() {
        isActive = false
        if let player {
            player.delegate = nil
            player.stop()
            player.media = nil
        }
        player = nil
        relay = nil
        currentURL = nil
        sawError = false
        bufferingProgress = 1
        bufferingCompleted = false
    }

    // MARK: - Spår

    private static func tracks(_ vlcTracks: [VLCMediaPlayer.Track], kind: TrackKind) -> [MediaTrack] {
        let descriptions = vlcTracks.enumerated().map { (index: Int32($0.offset), name: $0.element.trackName) }
        let mapped = VLCTrackMapping.tracks(from: descriptions, kind: kind)
        return zip(mapped, vlcTracks).map { track, vlcTrack in
            var track = track
            track.languageCode = track.languageCode ?? LanguageCode.normalize(vlcTrack.language)
            track.codec = fourCC(vlcTrack.codec)
            if kind == .audio, let channels = vlcTrack.audio?.channelsNumber, channels > 0 {
                track.channelCount = Int(channels)
            }
            track.isDefault = vlcTrack.isSelected
            return track
        }
    }

    /// VLC lagrar FourCC med första tecknet i lägsta byten.
    nonisolated static func fourCC(_ code: UInt32) -> String? {
        guard code != 0 else { return nil }
        let bytes = [0, 8, 16, 24].map { UInt8((code >> UInt32($0)) & 0xFF) }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private nonisolated static func audioDescription(for track: MediaTrack?) -> String? {
        guard let track else { return nil }
        if track.isAtmos { return "Atmos" }
        switch track.channelCount {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return nil
        }
    }
}

/// Tar emot VLC:s delegatanrop (på valfri tråd) och skickar dem vidare till motorn.
final class VLCEventRelay: NSObject, VLCMediaPlayerDelegate {
    enum Event: Sendable {
        case state(VLCMediaPlayerState)
        case buffering(Float)
    }

    private let handler: @Sendable (Event) -> Void

    init(handler: @escaping @Sendable (Event) -> Void) {
        self.handler = handler
    }

    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        handler(.state(newState))
    }

    func mediaPlayerBufferingChanged(_ progress: Float) {
        handler(.buffering(progress))
    }
}
