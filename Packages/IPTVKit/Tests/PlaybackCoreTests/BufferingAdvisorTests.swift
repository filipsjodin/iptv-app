import Foundation
import Testing
@testable import PlaybackCore

struct BufferingAdvisorTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// `#expect` tillåter inte muterande anrop direkt, så anropet går via en hjälpfunktion.
    private func stall(_ advisor: inout BufferingAdvisor, _ seconds: TimeInterval) -> Bool {
        advisor.recordStall(at: t0.addingTimeInterval(seconds))
    }

    @Test func threeStallsWithinWindowSuggest() {
        var advisor = BufferingAdvisor()
        #expect(!stall(&advisor, 0))
        #expect(!stall(&advisor, 20))
        #expect(stall(&advisor, 40))
    }

    @Test func stallsOutsideWindowDoNotAccumulate() {
        var advisor = BufferingAdvisor()
        #expect(!stall(&advisor, 0))
        #expect(!stall(&advisor, 30))
        // Det första stannandet har lämnat fönstret (61 s) när det tredje inträffar.
        #expect(!stall(&advisor, 61))
        // Nu ligger 30, 61 och 70 inom ett fönster från 70.
        #expect(stall(&advisor, 70))
    }

    @Test func resetClearsHistory() {
        var advisor = BufferingAdvisor()
        _ = stall(&advisor, 0)
        _ = stall(&advisor, 1)
        advisor.reset()
        #expect(!stall(&advisor, 2))
        #expect(!stall(&advisor, 3))
        #expect(stall(&advisor, 4))
    }

    @Test func historyIsClearedAfterSuggestion() {
        var advisor = BufferingAdvisor(threshold: 2, window: 10)
        _ = stall(&advisor, 0)
        #expect(stall(&advisor, 1))
        #expect(!stall(&advisor, 2))
    }
}
