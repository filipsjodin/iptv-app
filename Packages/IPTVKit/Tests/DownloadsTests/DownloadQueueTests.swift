import Foundation
import Testing
@testable import Downloads
import Core

func key(_ id: String, kind: ContentKind = .movie) -> DownloadKey {
    DownloadKey(profileID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                playlistID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                kind: kind, providerID: id)
}

@Suite struct DownloadQueueTests {
    @Test func enqueueStartsFirstAndQueuesRest() {
        var q = DownloadQueue(maxConcurrent: 1)
        let a = key("a"), b = key("b")
        #expect(q.enqueue(a) == [.requestConnection(a), .start(a)])
        #expect(q.enqueue(b) == [])
        #expect(q.states[a] == .downloading(progress: 0))
        #expect(q.states[b] == .queued)
    }

    @Test func maxConcurrentTwoStartsTwo() {
        var q = DownloadQueue(maxConcurrent: 2)
        _ = q.enqueue(key("a")); _ = q.enqueue(key("b")); _ = q.enqueue(key("c"))
        #expect(q.states[key("b")] == .downloading(progress: 0))
        #expect(q.states[key("c")] == .queued)
    }

    @Test func finishedStartsNext() {
        var q = DownloadQueue(maxConcurrent: 1)
        let a = key("a"), b = key("b")
        _ = q.enqueue(a); _ = q.enqueue(b)
        _ = q.apply(.progress(a, 0.5))
        #expect(q.states[a] == .downloading(progress: 0.5))
        let cmds = q.apply(.finished(a))
        #expect(cmds == [.releaseConnection(a), .requestConnection(b), .start(b)])
        #expect(q.states[a] == .completed)
        #expect(q.states[b] == .downloading(progress: 0))
    }

    @Test func revokeThenGrantResumesAutomatically() {
        var q = DownloadQueue(maxConcurrent: 1)
        let a = key("a"), b = key("b")
        _ = q.enqueue(a); _ = q.enqueue(b)
        let revoked = q.apply(.connectionRevoked)
        #expect(revoked == [.pause(a)])
        #expect(q.states[a] == .paused(.connectionNeeded))
        #expect(q.states[b] == .queued)   // b får inte ta platsen
        let granted = q.apply(.connectionGranted)
        #expect(granted == [.requestConnection(a), .start(a)])
        #expect(q.states[a] == .downloading(progress: 0))
        #expect(q.states[b] == .queued)
    }

    @Test func enqueueWhileRevokedStaysQueued() {
        var q = DownloadQueue(maxConcurrent: 1)
        _ = q.apply(.connectionRevoked)
        #expect(q.enqueue(key("a")) == [])
        #expect(q.states[key("a")] == .queued)
        #expect(q.apply(.connectionGranted) == [.requestConnection(key("a")), .start(key("a"))])
    }

    @Test func userPauseIsNotAutoResumed() {
        var q = DownloadQueue(maxConcurrent: 1)
        let a = key("a"), b = key("b")
        _ = q.enqueue(a); _ = q.enqueue(b)
        let cmds = q.apply(.userPaused(a))
        #expect(cmds == [.pause(a), .releaseConnection(a), .requestConnection(b), .start(b)])
        #expect(q.states[a] == .paused(.user))
        _ = q.apply(.connectionRevoked)
        _ = q.apply(.connectionGranted)
        _ = q.apply(.networkChanged(allowsCellular: false))
        _ = q.apply(.networkChanged(allowsCellular: true))
        _ = q.apply(.spaceChanged(freeBytes: 0))
        _ = q.apply(.spaceChanged(freeBytes: Int64.max))
        _ = q.apply(.finished(b))
        #expect(q.states[a] == .paused(.user))
        let resumed = q.apply(.userResumed(a))
        #expect(resumed == [.requestConnection(a), .start(a)])
    }

    @Test func wifiOnlyPausesOnCellularAndResumesOnWifi() {
        var q = DownloadQueue(maxConcurrent: 1, wifiOnly: true)
        let a = key("a")
        _ = q.enqueue(a)
        #expect(q.apply(.networkChanged(allowsCellular: false)) == [.pause(a), .releaseConnection(a)])
        #expect(q.states[a] == .paused(.waitingForWifi))
        #expect(q.enqueue(key("b")) == [])
        #expect(q.apply(.networkChanged(allowsCellular: true)) == [.requestConnection(a), .start(a)])
        #expect(q.states[a] == .downloading(progress: 0))
    }

    @Test func cellularAllowedWhenNotWifiOnly() {
        var q = DownloadQueue(maxConcurrent: 1, wifiOnly: false)
        _ = q.enqueue(key("a"))
        #expect(q.apply(.networkChanged(allowsCellular: false)) == [])
        #expect(q.states[key("a")] == .downloading(progress: 0))
    }

    @Test func failedReleasesConnectionAndStartsNext() {
        var q = DownloadQueue(maxConcurrent: 1)
        let a = key("a"), b = key("b")
        _ = q.enqueue(a); _ = q.enqueue(b)
        let cmds = q.apply(.failed(a, .badStatus))
        #expect(cmds == [.releaseConnection(a), .requestConnection(b), .start(b)])
        #expect(q.states[a] == .failed(.badStatus))
        // Retry via userResumed köar om.
        _ = q.apply(.userResumed(a))
        #expect(q.states[a] == .queued)
    }

    @Test func cancelRemovesAndReleases() {
        var q = DownloadQueue(maxConcurrent: 1)
        let a = key("a"), b = key("b")
        _ = q.enqueue(a); _ = q.enqueue(b)
        let cmds = q.apply(.userCancelled(a))
        #expect(cmds == [.cancel(a), .releaseConnection(a), .requestConnection(b), .start(b)])
        #expect(q.states[a] == nil)
        // Avbryt en köad rad ger bara cancel.
        _ = q.enqueue(key("c"))
        #expect(q.apply(.userCancelled(key("c"))) == [.cancel(key("c"))])
        #expect(q.apply(.userCancelled(key("nope"))) == [])
    }

    @Test func lowSpacePausesAsLowDiskSpace() {
        var q = DownloadQueue(maxConcurrent: 1, lowSpaceThresholdBytes: 1_000)
        let a = key("a")
        _ = q.enqueue(a)
        #expect(q.apply(.spaceChanged(freeBytes: 999)) == [.pause(a), .releaseConnection(a)])
        #expect(q.states[a] == .paused(.lowDiskSpace))
        #expect(q.apply(.spaceChanged(freeBytes: 5_000)) == [.requestConnection(a), .start(a)])
    }

    @Test func duplicateEnqueueIgnored() {
        var q = DownloadQueue(maxConcurrent: 1)
        let a = key("a")
        _ = q.enqueue(a)
        #expect(q.enqueue(a) == [])
        #expect(q.states.count == 1)
        _ = q.apply(.finished(a))
        #expect(q.enqueue(a) == [])
        #expect(q.states[a] == .completed)
    }

    @Test func eventsForUnknownKeysAreIgnoredAndProgressIsClamped() {
        var q = DownloadQueue(maxConcurrent: 1)
        #expect(q.apply(.finished(key("x"))) == [])
        #expect(q.apply(.failed(key("x"), .unknown)) == [])
        #expect(q.apply(.userPaused(key("x"))) == [])
        _ = q.enqueue(key("a"))
        _ = q.apply(.progress(key("a"), 7))
        #expect(q.states[key("a")] == .downloading(progress: 1))
        _ = q.apply(.progress(key("a"), .nan))
        #expect(q.states[key("a")] == .downloading(progress: 0))
        #expect(DownloadQueue(maxConcurrent: 0).maxConcurrent == 1)
    }
}
