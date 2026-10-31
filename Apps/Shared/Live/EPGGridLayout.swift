import Core
import Foundation

/// Ren geometri för tablårutnätet: tid → x-koordinat. Inga vyer, ingen tillstånd; testas separat.
/// `origin` är rutnätets vänstra kant (x = 0) och `pointsPerMinute` skalan.
struct EPGGridLayout: Sendable {
    /// Minsta bredd för en programruta, så att även ett mycket kort program syns och går att välja.
    static let minimumWidth: CGFloat = 24

    let origin: Date
    let pointsPerMinute: CGFloat

    init(origin: Date, pointsPerMinute: CGFloat) {
        self.origin = origin
        self.pointsPerMinute = pointsPerMinute
    }

    /// x för en tidpunkt; linjär i minuter från `origin` (negativ före `origin`).
    func x(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(origin) / 60) * pointsPerMinute
    }

    /// Tidpunkten vid x (omvänd till `x(for:)`).
    func date(forX x: CGFloat) -> Date {
        origin.addingTimeInterval(TimeInterval(x / pointsPerMinute) * 60)
    }

    /// Programrutans läge och bredd. Ett program som börjar före `origin` beskärs till `origin`; bredden är minst
    /// `minimumWidth`.
    func frame(for program: EPGProgram) -> (x: CGFloat, width: CGFloat) {
        let startX = max(0, x(for: program.start))
        let endX = x(for: program.end)
        return (startX, max(Self.minimumWidth, endX - startX))
    }

    /// Tidsfönstret som syns för en horisontell förskjutning och en bredd (båda i punkter).
    func visibleRange(offset: CGFloat, viewport: CGFloat) -> ClosedRange<Date> {
        let lower = date(forX: offset)
        let upper = date(forX: offset + max(0, viewport))
        return lower...max(lower, upper)
    }

    /// x för en tidpunkt (nu-linjen): samma som `x(for:)`.
    var nowX: (Date) -> CGFloat { { x(for: $0) } }
}
