import Testing
@testable import Downloads

struct ProgressThrottleTests {
    @Test func firstValueAlwaysEmitted() {
        var t = ProgressThrottle()
        let r1 = t.shouldEmit(task: 1, written: 1, total: 1000, now: 0)
        #expect(r1)
    }

    @Test func tinyChangesWithinIntervalAreDropped() {
        var t = ProgressThrottle()
        _ = t.shouldEmit(task: 1, written: 0, total: 1000, now: 0)
        let r2 = t.shouldEmit(task: 1, written: 2, total: 1000, now: 0.01)
        #expect(!r2)
        let r3 = t.shouldEmit(task: 1, written: 4, total: 1000, now: 0.02)
        #expect(!r3)
    }

    @Test func fractionStepEmits() {
        var t = ProgressThrottle()
        _ = t.shouldEmit(task: 1, written: 0, total: 1000, now: 0)
        let r4 = t.shouldEmit(task: 1, written: 5, total: 1000, now: 0.01)
        #expect(r4)
    }

    @Test func intervalEmitsEvenWithoutStep() {
        var t = ProgressThrottle()
        _ = t.shouldEmit(task: 1, written: 0, total: 1_000_000, now: 0)
        let r5 = t.shouldEmit(task: 1, written: 1, total: 1_000_000, now: 0.1)
        #expect(!r5)
        let r6 = t.shouldEmit(task: 1, written: 2, total: 1_000_000, now: 0.26)
        #expect(r6)
    }

    @Test func finalValueAlwaysEmitted() {
        var t = ProgressThrottle()
        _ = t.shouldEmit(task: 1, written: 999_999, total: 1_000_000, now: 0)
        let r7 = t.shouldEmit(task: 1, written: 1_000_000, total: 1_000_000, now: 0.001)
        #expect(r7)
    }

    @Test func unknownTotalIsTimeDriven() {
        var t = ProgressThrottle()
        _ = t.shouldEmit(task: 1, written: 10, total: -1, now: 0)
        let r8 = t.shouldEmit(task: 1, written: 5000, total: -1, now: 0.1)
        #expect(!r8)
        let r9 = t.shouldEmit(task: 1, written: 9000, total: -1, now: 0.3)
        #expect(r9)
    }

    @Test func tasksAreIndependentAndForgettable() {
        var t = ProgressThrottle()
        _ = t.shouldEmit(task: 1, written: 0, total: 1000, now: 0)
        let r10 = t.shouldEmit(task: 2, written: 0, total: 1000, now: 0)
        #expect(r10)
        t.forget(task: 1)
        let r11 = t.shouldEmit(task: 1, written: 1, total: 1000, now: 0.001)
        #expect(r11)
    }
}

struct DownloadErrorMappingTests {
    typealias C = DownloadErrorMapping.Code

    @Test func outOfSpaceCodes() {
        #expect(DownloadErrorMapping.sessionFailure([C(domain: "NSURLErrorDomain", code: -3003)]) == .noSpace)
        #expect(DownloadErrorMapping.sessionFailure([C(domain: "NSURLErrorDomain", code: -3000)]) == .noSpace)
        #expect(DownloadErrorMapping.sessionFailure([C(domain: "NSCocoaErrorDomain", code: 640)]) == .noSpace)
        #expect(DownloadErrorMapping.sessionFailure([C(domain: "NSPOSIXErrorDomain", code: 28)]) == .noSpace)
    }

    @Test func underlyingErrorCounts() {
        let chain = [C(domain: "NSURLErrorDomain", code: -1), C(domain: "NSPOSIXErrorDomain", code: 28)]
        #expect(DownloadErrorMapping.sessionFailure(chain) == .noSpace)
    }

    @Test func otherUrlErrorsAreNetwork() {
        #expect(DownloadErrorMapping.sessionFailure([C(domain: "NSURLErrorDomain", code: -1009)]) == .network)
        #expect(DownloadErrorMapping.sessionFailure([C(domain: "Other", code: 1)]) == .unknown)
        #expect(DownloadErrorMapping.sessionFailure([]) == .unknown)
    }

    @Test func storageFailureDistinguishesSpace() {
        #expect(DownloadErrorMapping.storageFailure([C(domain: "NSCocoaErrorDomain", code: 640)]) == .noSpace)
        #expect(DownloadErrorMapping.storageFailure([C(domain: "NSCocoaErrorDomain", code: 513)]) == .storage)
    }
}
