import Core
import Foundation
import Testing
@testable import IPTVApp

private let origin = Date(timeIntervalSince1970: 1_800_000_000)

private func program(_ startMinutes: Double, _ endMinutes: Double) -> EPGProgram {
    EPGProgram(channelID: "c", start: origin.addingTimeInterval(startMinutes * 60),
               end: origin.addingTimeInterval(endMinutes * 60), title: "P")
}

@Suite struct EPGGridLayoutTests {
    private let layout = EPGGridLayout(origin: origin, pointsPerMinute: 4)

    @Test func xIsLinearInMinutes() {
        #expect(layout.x(for: origin) == 0)
        #expect(layout.x(for: origin.addingTimeInterval(30 * 60)) == 120)
        #expect(layout.x(for: origin.addingTimeInterval(90 * 60)) == 360)
    }

    @Test func programBeforeOriginIsClipped() {
        let frame = layout.frame(for: program(-30, 30))
        #expect(frame.x == 0)
        #expect(frame.width == 120)
    }

    @Test func veryShortProgramGetsMinimumWidth() {
        let frame = layout.frame(for: program(10, 10.1))
        #expect(frame.x == 40)
        #expect(frame.width == EPGGridLayout.minimumWidth)
    }

    @Test func visibleRangeMatchesOffsetAndViewport() {
        let range = layout.visibleRange(offset: 240, viewport: 480)
        #expect(range.lowerBound == origin.addingTimeInterval(60 * 60))
        #expect(range.upperBound == origin.addingTimeInterval(180 * 60))
    }

    @Test func nowXMatchesXForNow() {
        let now = origin.addingTimeInterval(47 * 60)
        #expect(layout.nowX(now) == layout.x(for: now))
    }
}
