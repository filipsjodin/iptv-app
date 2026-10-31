import Foundation

/// Sorterad samling cues med snabbt uppslag på uppspelningstid.
public struct SubtitleTrack: Sendable {
    public static let maxOffset: Double = 600

    private let cues: [SubtitleCue]

    public init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
    }

    /// Aktiv cue vid `time + offset` (start inklusive, slut exklusivt).
    public func cue(at time: Double, offset: Double) -> SubtitleCue? {
        let t = time + offset
        guard t.isFinite else { return nil }
        // Binärsökning: sista cue med start <= t.
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        // Överlappande cues: titta några steg bakåt efter en som ännu är aktiv.
        var i = lo - 1
        var steps = 0
        while i >= 0, steps < 8 {
            if t < cues[i].end { return cues[i] }
            i -= 1
            steps += 1
        }
        return nil
    }

    /// Begränsar till −600…+600 s och avrundar till 0,1 s.
    public static func clampOffset(_ offset: Double) -> Double {
        guard offset.isFinite else { return 0 }
        let clamped = min(max(offset, -maxOffset), maxOffset)
        let rounded = (clamped * 10).rounded() / 10
        return rounded == 0 ? 0 : rounded   // undvik −0
    }
}
