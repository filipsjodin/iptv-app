import Foundation
import PlaybackCore
import Subtitles

public enum PlaybackFailure: Error, Equatable, Sendable {
    case unsupportedFormat, network, timeout, unknown
}

public enum PlaybackState: Equatable, Sendable {
    case idle, loading, playing, paused, buffering, ended
    case failed(PlaybackFailure)
}

/// Gemensamt gränssnitt för uppspelningsmotorer (AVPlayer, VLC).
@MainActor
public protocol PlayerEngine: AnyObject {
    var kind: EngineKind { get }
    var state: PlaybackState { get }
    var currentTime: Double { get }
    var duration: Double? { get }
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var selectedAudioID: String? { get }
    var selectedSubtitleID: String? { get }
    var videoInfo: VideoInfo { get }
    var onStateChange: ((PlaybackState) -> Void)? { get set }

    /// Laddar strömmen och startar uppspelning. Kastar `PlaybackFailure` (timeout 15 s tills strömmen är redo),
    /// eller `CancellationError` om laddningen ersätts av `close()`/en ny `load` eller om tasken avbryts.
    func load(url: URL, startAt: Double?) async throws
    func play()
    func pause()
    func seek(to seconds: Double) async
    /// `nil` avmarkerar ljudspår där motorn tillåter det (AVPlayer: bara om gruppen tillåter tomt val).
    func select(audioID: String?)
    /// `nil` stänger av undertexter.
    func select(subtitleID: String?)
    func close()
    /// Som `close()`, men väntar tills motorn har släppt anslutningen till servern (begränsad väntan).
    /// Används före nästa motor/ström öppnas, eftersom många konton bara tillåter en anslutning
    /// (max_connections == 1). Standard: `close()` utan väntan.
    func closeAndWait() async

    /// Lägger till en extern undertext (SRT/WebVTT på disk) som spår `ext:<fileID>` i `subtitleTracks`.
    /// Läsning och tolkning sker utanför huvudtråden. Kastar `ExternalSubtitleError`. Standard: `.unsupported`.
    func addExternalSubtitle(fileURL: URL, language: String?, title: String, fileID: Int) async throws
    /// AVPlayer: cue för vald extern text vid given uppspelningstid (annars nil). VLC: nil (VLC ritar själv).
    /// Värdet fångar valt spår och förskjutning; läs egenskapen på nytt vid varje uppslag.
    var externalCueProvider: ((Double) -> SubtitleCue?)? { get }
    /// Förskjutning i sekunder, klampad via `SubtitleTrack.clampOffset`. Uppslagstid = uppspelningstid + förskjutning,
    /// så ett positivt värde visar texten tidigare och ett negativt senare.
    func setSubtitleOffset(_ seconds: Double)
}

extension PlayerEngine {
    public func closeAndWait() async {
        close()
    }

    public func addExternalSubtitle(fileURL: URL, language: String?, title: String, fileID: Int) async throws {
        throw ExternalSubtitleError.unsupported
    }

    public var externalCueProvider: ((Double) -> SubtitleCue?)? { nil }

    public func setSubtitleOffset(_ seconds: Double) {}
}
