import Testing
@testable import PlaybackCore

@Test func livePlanHasNoStartOffsetAndNoLimit() {
    let plan = PreviewPlan.live()
    #expect(plan.startAt == nil)
    #expect(plan.maxDuration == nil)
}
