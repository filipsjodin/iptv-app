import Foundation

/// Ren layoutberäkning för affischgrid och hyllor: affischbredd och kolumner ur tillgänglig bredd (inte ur
/// enhetstyp, så att Split View och Slide Over blir rätt).
public struct LayoutMetrics: Sendable, Equatable {
    public static let sideMargin = 16.0
    public static let minPosterWidth = 100.0
    public static let maxPosterWidth = 180.0
    public static let regularThreshold = 700.0

    public let availableWidth: Double
    public let dynamicTypeScale: Double

    public init(availableWidth: Double, dynamicTypeScale: Double = 1) {
        // Icke-ändliga eller negativa mått räknas som 0 (ger minsta layouten).
        self.availableWidth = availableWidth.isFinite ? max(0, availableWidth) : 0
        self.dynamicTypeScale = dynamicTypeScale.isFinite ? dynamicTypeScale : 1
    }

    public var spacing: Double { 12 }

    public var isRegular: Bool { availableWidth >= Self.regularThreshold }

    /// Önskad affischbredd före kolumnberäkningen.
    private var targetWidth: Double {
        if availableWidth < 430 { return 110 }
        if availableWidth < Self.regularThreshold { return 130 }
        return 150
    }

    private var contentWidth: Double { availableWidth - 2 * Self.sideMargin }

    public var columns: Int {
        let raw = ((contentWidth + spacing) / (targetWidth + spacing)).rounded(.down)
        var count = max(2, Int(max(0, raw)))
        if dynamicTypeScale > 1.3 { count = max(2, count - 1) }
        return count
    }

    /// Fyller kolumnen, klampad till 100…180.
    public var posterWidth: Double {
        let n = Double(columns)
        let fill = (contentWidth - (n - 1) * spacing) / n
        return min(Self.maxPosterWidth, max(Self.minPosterWidth, fill))
    }
}
