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

    @Test func programBeforeOriginIsClipped() throws {
        let frame = try #require(layout.frame(for: program(-30, 30)))
        #expect(frame.x == 0)
        #expect(frame.width == 120)
    }

    @Test func veryShortProgramGetsMinimumWidth() throws {
        let frame = try #require(layout.frame(for: program(10, 10.1)))
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

    @Test func programFullyBeforeOriginHasNoFrame() {
        #expect(layout.frame(for: program(-60, -30)) == nil)
        #expect(layout.frame(for: program(-60, 0)) == nil)
    }

    @Test func zeroOrNegativeLengthHasNoFrame() {
        #expect(layout.frame(for: program(10, 10)) == nil)
        #expect(layout.frame(for: program(20, 10)) == nil)
    }

    @Test func negativeOffsetAndViewportAreSafe() {
        let before = layout.visibleRange(offset: -120, viewport: 240)
        #expect(before.lowerBound == origin.addingTimeInterval(-30 * 60))
        #expect(before.upperBound == origin.addingTimeInterval(30 * 60))
        let empty = layout.visibleRange(offset: 240, viewport: -100)
        #expect(empty.lowerBound == empty.upperBound)
    }

    @Test func hourWindowIsPaddedAndClampedToSpan() {
        // Synligt 60-180 min => timmar 1...3, ±1 => 0...4.
        #expect(EPGGridModel.hourWindow(layout: layout, spanHours: 36, offset: 240, viewport: 480) == 0...4)
        // Negativ förskjutning klampas till 0.
        #expect(EPGGridModel.hourWindow(layout: layout, spanHours: 36, offset: -5000, viewport: 100).lowerBound == 0)
        // Långt bortom spannet klampas till sista timmen (35).
        let far = EPGGridModel.hourWindow(layout: layout, spanHours: 36, offset: 4 * 60 * 100, viewport: 4 * 60 * 5)
        #expect(far.upperBound == 35)
        #expect(far.lowerBound <= far.upperBound)
    }

    @Test func flowRemovesOverlapAndDuplicates() {
        func cell(_ id: String, _ x: CGFloat, _ width: CGFloat) -> EPGCell {
            EPGCell(id: id, program: program(0, 1), x: x, width: width, timeText: "", rangeText: "")
        }
        let result = EPGGridModel.flow([cell("c", 50, 100), cell("b", 0, 100), cell("a", 0, 100)])
        // "a" och "b" börjar samma plats: "a" först, "b" helt övertäckt och utelämnad; "c" börjar efter 100.
        #expect(result.map(\.id) == ["a", "c"])
        #expect(result[0].gap == 0)
        #expect(result[0].drawWidth == 100)
        #expect(result[1].gap == 0)
        #expect(result[1].drawWidth == 50)
    }

    @Test func evictionKeepsPinnedAndDropsOldest() {
        let order = ["a", "b", "c", "d", "e"]
        #expect(EPGGridModel.evictionVictims(order: order, pinned: [], cap: 5).isEmpty)
        #expect(EPGGridModel.evictionVictims(order: order, pinned: [], cap: 3) == ["a", "b"])
        #expect(EPGGridModel.evictionVictims(order: order, pinned: ["a"], cap: 3) == ["b", "c"])
    }
}
