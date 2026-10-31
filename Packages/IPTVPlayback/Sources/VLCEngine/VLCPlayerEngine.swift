import Foundation
import Playback
import PlaybackCore
import Subtitles
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
    /// Längsta väntan i `closeAndWait()` på att föregående spelare släppts.
    private let closeWaitLimit: Duration
    /// Signalerar när den senast stängda spelaren har släppts i bakgrunden.
    private var lastRelease: VLCReleaseSignal?
    /// En ny spelare per laddning, så att sena händelser från en tidigare ström aldrig når den nya.
    private var player: VLCMediaPlayer?
    private var relay: VLCEventRelay?
    private var currentURL: URL?
    /// Externa undertexter som lagts till som "slave"-spår; `vlcIndex` är positionen i VLC:s textspårslista.
    private var externalEntries: [ExternalEntry] = []
    private var subtitleOffset: Double = 0

    private struct ExternalEntry {
        var vlcIndex: Int
        var track: MediaTrack
    }
    /// Ökas vid varje load/close så att en avbruten laddning inte skriver över nyare state.
    private var generation = 0
    private var isActive = false
    // Historik för aktuell generation, från delegatens tillståndshändelser.
    private var sawError = false
    private var sawStart = false
    private var sawPlaying = false
    /// Senaste buffringsvärde i [0, 1]. Uppdateras bara när motorn är aktiv.
    private var bufferingProgress: Float = 1
    /// Sant när VLC rapporterat buffring 1.0 för aktuell laddning (används som klarsignal i `load`).
    private var bufferingCompleted = false

    /// Titeln för Kontrollcenter/Now Playing. Appen visar den via `MPNowPlayingInfoCenter`; aldrig URL:en.
    public let title: String?

    /// - Parameter title: visas i Kontrollcenter (via appen). Ange aldrig en URL.
    public init(title: String? = nil, loadTimeout: Duration = .seconds(15), closeWaitLimit: Duration = .seconds(2)) {
        self.title = title
        self.loadTimeout = loadTimeout
        self.closeWaitLimit = closeWaitLimit
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
        var tracks = Self.tracks(player.textTracks, kind: .subtitle)
        // Slave-spåren byter id till `ext:<fileID>` (språk och titel ur releasenamnet).
        for entry in externalEntries {
            if let i = tracks.firstIndex(where: { $0.id == "\(entry.vlcIndex)" }) { tracks[i] = entry.track }
        }
        return tracks
    }

    public var selectedAudioID: String? {
        guard isActive, let player else { return nil }
        return player.audioTracks.firstIndex(where: \.isSelected).map { "\($0)" }
    }

    public var selectedSubtitleID: String? {
        guard isActive, let player else { return nil }
        guard let index = player.textTracks.firstIndex(where: \.isSelected) else { return nil }
        return externalEntries.first { $0.vlcIndex == index }?.track.id ?? "\(index)"
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
        bufferingProgress = 0
        state = .loading

        do {
            guard let media = VLCMedia(url: url) else { throw PlaybackFailure.unknown }
            if let startAt, startAt > 0 {
                media.addOption(":start-time=\(startAt)")
            }
            // Spelaren skapas i en synkron hjälpmetod: ingen lokal referens till den lever kvar över väntan nedan.
            // Annars skulle en `close()` under laddningen lämna en stark referens här, och den sista
            // frigöringen (som väntar in libvlc) skulle ske på huvudtråden när laddningen avbryts.
            startPlayer(media: media, url: url, generation: gen)

            try await waitUntilPlaying(deadline: .now + loadTimeout, generation: gen)
            try checkCurrent(gen)
            // Som AVPlayerEngine: en lyckad laddning slutar alltid i .playing. Senare händelser tar över därifrån.
            bufferingProgress = 1
            isActive = true
            state = .playing
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

    /// Skapar och startar spelaren för `media`. Bara `self.player` håller den.
    private func startPlayer(media: VLCMedia, url: URL, generation gen: Int) {
        let player = VLCMediaPlayer(library: Self.quietLibrary)
        // DispatchQueue.main är FIFO, så händelserna hanteras i den ordning VLC skickade dem.
        let relay = VLCEventRelay { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.handle(event, generation: gen) }
            }
        }
        player.delegate = relay
        player.drawable = drawable
        player.media = media
        self.player = player
        self.relay = relay
        currentURL = url
        player.play()
    }

    /// Klar när spelaren spelar och antingen buffringen är klar, video visas eller tiden har börjat gå.
    /// Läser `self.player` i varje varv (ingen referens hålls över `sleep`); saknas den är laddningen ersatt.
    private func waitUntilPlaying(deadline: ContinuousClock.Instant, generation gen: Int) async throws {
        var started = false
        var opened = false
        while true {
            try checkCurrent(gen)
            // Delegatens historik fångar korta förlopp (opening → stopped) som pollningen kan missa.
            started = started || sawStart
            opened = opened || sawPlaying
            let failure: PlaybackFailure = opened ? .unknown : .network
            if sawError { throw failure }
            guard let vlcState = player?.state else { throw CancellationError() }
            switch vlcState {
            case .opening:
                started = true
            case .playing, .paused:
                started = true
                opened = true
                if bufferingCompleted || hasStartedOutput() { return }
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

    /// Video visas eller tiden har börjat gå (läser `self.player`; ingen lokal referens efteråt).
    private func hasStartedOutput() -> Bool {
        guard let player else { return false }
        return player.hasVideoOut || (player.time.value?.doubleValue ?? 0) > 0
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
        if let entry = externalEntries.first(where: { $0.track.id == subtitleID }) {
            guard tracks.indices.contains(entry.vlcIndex) else { return }
            tracks[entry.vlcIndex].isSelectedExclusively = true
            return
        }
        guard let index = Int(subtitleID), tracks.indices.contains(index) else { return }
        tracks[index].isSelectedExclusively = true
    }

    // MARK: - Externa undertexter

    /// Lägger till filen som VLC-"slave" (VLC läser och ritar själv) och väntar begränsat (3 s) tills det nya
    /// textspåret dyker upp i spårlistan; det mappas till `ext:<fileID>`.
    public func addExternalSubtitle(fileURL: URL, language: String?, title: String, fileID: Int) async throws {
        guard isActive, player != nil else { throw ExternalSubtitleError.notLoaded }
        let id = MediaTrack.externalID(fileID: fileID)
        if externalEntries.contains(where: { $0.track.id == id }) { return }
        guard fileURL.isFileURL else { throw ExternalSubtitleError.unreadable }
        // Filkontrollen görs utanför huvudtråden; tillståndet kontrolleras om efteråt.
        let path = fileURL.path
        let exists = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: path) }.value
        guard exists else { throw ExternalSubtitleError.unreadable }
        guard isActive, player != nil else { throw ExternalSubtitleError.notLoaded }
        if externalEntries.contains(where: { $0.track.id == id }) { return }
        let gen = generation
        let before = player?.textTracks.count ?? 0
        _ = player?.addPlaybackSlave(fileURL, type: .subtitle, enforce: false)
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            guard gen == generation, isActive, let current = player else { throw CancellationError() }
            let count = current.textTracks.count
            if count > before {
                let track = ExternalSubtitleSet.mediaTrack(fileID: fileID, language: language, title: title)
                externalEntries.append(ExternalEntry(vlcIndex: count - 1, track: track))
                return
            }
            if ContinuousClock.now >= deadline { throw ExternalSubtitleError.unreadable }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// VLC ritar själv: ingen överlagring.
    public var externalCueProvider: ((Double) -> SubtitleCue?)? { nil }

    /// VLC:s fördröjning är positiv när texten visas senare (mikrosekunder); vår förskjutning är uppslagstid
    /// = tid + förskjutning, så tecknet vänds.
    public func setSubtitleOffset(_ seconds: Double) {
        subtitleOffset = SubtitleTrack.clampOffset(seconds)
        player?.currentVideoSubTitleDelay = Int((-subtitleOffset * 1_000_000).rounded())
    }

    public func close() {
        generation += 1
        tearDown()
        state = .idle
    }

    /// Stänger och väntar (högst `closeWaitLimit`, standard 2 s) tills spelaren har släppts i bakgrunden,
    /// dvs. tills libvlc stoppat och stängt anslutningen. Svarar inte servern ger vi upp efter gränsen
    /// i stället för att låta användaren vänta; nästa ström öppnas då ändå.
    public func closeAndWait() async {
        close()
        guard let release = lastRelease else { return }
        let deadline = ContinuousClock.now + closeWaitLimit
        while !release.isFinished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Sant om aktuell spelare skapades mot det tysta biblioteket (för tester).
    var playerUsesQuietLibrary: Bool { player?.libraryInstance === Self.quietLibrary }

    /// Sant medan en stängd spelare ännu inte har släppts i bakgrunden (för tester).
    var isReleasePending: Bool { lastRelease.map { !$0.isFinished } ?? false }

    /// Knyter `probe` till aktuell spelare (associerat objekt), så att ett test ser på vilken tråd spelaren
    /// frigörs: `probe` släpps när spelaren avallokeras. `false` om ingen spelare finns.
    func attachDeallocProbe(_ probe: AnyObject) -> Bool {
        guard let player else { return false }
        objc_setAssociatedObject(player, &Self.deallocProbeKey, probe, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return true
    }

    private nonisolated(unsafe) static var deallocProbeKey: UInt8 = 0

    // MARK: - Händelser

    private func handle(_ event: VLCEventRelay.Event, generation gen: Int) {
        guard gen == generation, let player else { return }
        switch event {
        case .state(let reported):
            // Värdet i händelsen används bara som historik; tillståndet läses alltid om från spelaren.
            switch reported {
            case .error: sawError = true
            case .opening: sawStart = true
            case .playing, .paused: sawStart = true; sawPlaying = true
            default: break
            }
            apply(player.state)
        case .buffering(let progress):
            if progress >= 1 { bufferingCompleted = true }
            // Under laddningen räknas bara klarsignalen ovan; state ändras först när motorn är aktiv.
            guard isActive else { return }
            bufferingProgress = progress
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
            // Delegat, stopp och drawable kopplas loss på huvudtråden: inga fler händelser och ingen
            // mer video i vår vy.
            player.delegate = nil
            player.stop()
            player.media = nil
            player.drawable = nil
        }
        // När sista referensen till VLCMediaPlayer släpps väntar libvlc in stoppet (t.ex. en hängande
        // nätverksöppning mot en server som inte svarar). Den sista referensen lämnas därför till en
        // bakgrundskö så att huvudtråden aldrig blockeras; `closeAndWait()` väntar (begränsat) på signalen.
        // Spelaren flyttas direkt från `self.player` in i lådan, utan någon namngiven lokal referens som annars
        // skulle leva kvar på huvudtråden till slutet av blocket (och kunna bli den sista referensen).
        if let box = player.take().map(VLCPlayerReleaseBox.init) {
            let signal = VLCReleaseSignal()
            lastRelease = signal
            DispatchQueue.global(qos: .utility).async {
                box.release()
                signal.finish()
            }
        }
        relay = nil
        currentURL = nil
        externalEntries = []
        subtitleOffset = 0
        sawError = false
        sawStart = false
        sawPlaying = false
        bufferingProgress = 1
        bufferingCompleted = false
    }

    // MARK: - Spår

    /// Spår-ID är positionen i VLC:s spårlista. I live-TS kan spår tillkomma eller försvinna,
    /// så ett ID kan flytta till ett annat spår mellan två läsningar.
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
            // VLC exponerar inget "default"-spår, bara vilket som är valt; det valda räknas som standard.
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

/// Ett delat, tyst libvlc-bibliotek för alla spelare.
///
/// Standardbiblioteket (`VLCLibrary.shared()`) loggar via libvlc:s egna loggare (stderr/os_log), och libvlc
/// skriver hela MRL:en – med användarnamn och lösenord i Xtream-URL:er – i bl.a. felmeddelanden. Därför:
/// `--quiet` stänger av libvlc:s konsolutskrift, och en loggare som kastar allt ersätter libvlc:s
/// standardloggare (när `loggers` sätts registreras VLCKit:s egen logg-callback, som bara når våra loggare).
extension VLCPlayerEngine {
    nonisolated static let libraryOptions = ["--quiet"]

    static let quietLibrary: VLCLibrary = {
        let library = VLCLibrary(options: libraryOptions)
        library.loggers = [VLCSilentLogger()]
        return library
    }()

    /// Sant om det delade biblioteket bara har tysta loggare (för tester).
    static var quietLibraryIsSilent: Bool {
        guard let loggers = quietLibrary.loggers, !loggers.isEmpty else { return false }
        return loggers.allSatisfy { $0 is VLCSilentLogger }
    }
}

/// Loggare som kastar alla meddelanden från libvlc (de kan innehålla URL:er med lösenord).
final class VLCSilentLogger: NSObject, VLCLogging {
    // Anropas från libvlc:s trådar; värdet läses bara och ändras aldrig.
    var level: VLCLogLevel = VLCLogLevel(rawValue: 0)!  // kVLCLogLevelError

    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {}
}

/// Håller den sista referensen till en stängd spelare tills den släpps på en bakgrundskö.
private final class VLCPlayerReleaseBox: @unchecked Sendable {
    // @unchecked Sendable: spelaren rörs bara av bakgrundskön efter överlämningen.
    private var player: VLCMediaPlayer?
    init(_ player: VLCMediaPlayer) { self.player = player }
    func release() { player = nil }
}

/// Trådsäker flagga som sätts när en spelare har släppts.
final class VLCReleaseSignal: @unchecked Sendable {
    // @unchecked Sendable: `finished` skyddas av `lock`.
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.withLock { finished } }
    func finish() { lock.withLock { finished = true } }
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
        handler(.buffering(Self.normalizedBuffering(progress)))
    }

    /// VLCKit 4.0.0-a25 skickar libvlc:s `on_buffering_changed` vidare oförändrat, och
    /// `libvlc_media_player.h` anger "buffering in the range [0:1]" (inte 0–100 som den gamla
    /// händelsen `new_cache`). Värdet kläms ändå till [0, 1] som skydd.
    static func normalizedBuffering(_ raw: Float) -> Float {
        raw.isFinite ? min(max(raw, 0), 1) : 0
    }
}
