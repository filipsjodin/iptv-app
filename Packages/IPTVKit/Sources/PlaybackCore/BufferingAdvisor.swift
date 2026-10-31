import Foundation

/// Räknar buffringsstarter i en live-ström och säger till när det blivit så många inom ett tidsfönster att det är
/// värt att föreslå en lägre kvalitet. Ren logik utan klocka: tiden skickas in.
public struct BufferingAdvisor: Sendable {
    private let threshold: Int
    private let window: TimeInterval
    private var stalls: [Date] = []

    /// - Parameters:
    ///   - threshold: antal stannanden som ger ett förslag.
    ///   - window: tidsfönster i sekunder som stannandena ska ligga inom.
    public init(threshold: Int = 3, window: TimeInterval = 60) {
        self.threshold = max(1, threshold)
        self.window = window
    }

    /// Anropas vid varje buffringsstart. `true` när `threshold` stannanden skett inom `window` sekunder; nollställs
    /// efter ett förslag och vid kanalbyte.
    public mutating func recordStall(at: Date) -> Bool {
        stalls.append(at)
        stalls.removeAll { at.timeIntervalSince($0) > window }
        guard stalls.count >= threshold else { return false }
        stalls.removeAll()
        return true
    }

    public mutating func reset() {
        stalls.removeAll()
    }
}
