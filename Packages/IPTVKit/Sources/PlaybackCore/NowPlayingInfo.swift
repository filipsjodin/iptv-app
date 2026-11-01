import Foundation

/// Ren modell för det som visas i Kontrollcenter/låsskärm: titel, tid och hastighet. Aldrig URL:er eller
/// annat som identifierar spellista eller konto.
public struct NowPlayingInfo: Sendable, Equatable {
    public let title: String
    public let elapsed: Double
    public let duration: Double?
    public let isPlaying: Bool
    public let isLive: Bool

    public init(title: String, elapsed: Double, duration: Double?, isPlaying: Bool, isLive: Bool) {
        self.title = title
        self.elapsed = elapsed
        self.duration = duration
        self.isPlaying = isPlaying
        self.isLive = isLive
    }

    /// 1 när det spelar, 0 när det är pausat.
    public var playbackRate: Double { isPlaying ? 1 : 0 }

    /// Längden att visa: nil för live och för okänd eller ogiltig (≤ 0, NaN, oändlig) längd.
    public var durationForDisplay: Double? {
        guard !isLive, let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    /// Förfluten tid: minst 0 och högst längden när den är känd.
    public var elapsedClamped: Double {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        if let durationForDisplay { return min(elapsed, durationForDisplay) }
        return elapsed
    }
}
