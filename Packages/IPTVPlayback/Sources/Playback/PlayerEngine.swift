import Foundation
import PlaybackCore

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
}
