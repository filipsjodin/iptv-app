import Foundation

/// Slår ihop täta förloppsanrop per överföring. Släpper igenom första värdet, varje ändring på minst
/// `minFractionStep`, varje värde efter minst `minInterval` sekunder sedan senaste, och alltid slutvärdet
/// (alla byte hämtade). Tiden injiceras så att logiken kan testas.
public struct ProgressThrottle: Sendable {
    public var minFractionStep: Double
    public var minInterval: TimeInterval
    private var last: [Int: (fraction: Double, time: TimeInterval)] = [:]

    public init(minFractionStep: Double = 0.005, minInterval: TimeInterval = 0.25) {
        self.minFractionStep = minFractionStep
        self.minInterval = minInterval
    }

    /// `total <= 0` betyder okänd storlek; då styr bara tiden.
    public mutating func shouldEmit(task: Int, written: Int64, total: Int64, now: TimeInterval) -> Bool {
        let isFinal = total > 0 && written >= total
        let fraction = total > 0 ? Double(written) / Double(total) : 0
        guard let previous = last[task] else {
            last[task] = (fraction, now)
            return true
        }
        if isFinal || abs(fraction - previous.fraction) >= minFractionStep || now - previous.time >= minInterval {
            last[task] = (fraction, now)
            return true
        }
        return false
    }

    /// Glöm överföringen (klar, avbruten eller misslyckad).
    public mutating func forget(task: Int) {
        last[task] = nil
    }
}
