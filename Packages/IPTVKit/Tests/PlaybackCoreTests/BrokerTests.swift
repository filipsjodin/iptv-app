import Foundation
import Testing
@testable import PlaybackCore

/// Räknar onRevoke-anrop per nyckel.
private actor RevokeLog {
    private(set) var counts: [String: Int] = [:]
    private(set) var order: [String] = []
    func hit(_ name: String) { counts[name, default: 0] += 1; order.append(name) }
    func count(_ name: String) -> Int { counts[name] ?? 0 }
}

private func revoker(_ log: RevokeLog, _ name: String, delayMs: Int = 0) -> @Sendable () async -> Void {
    {
        await log.hit(name)
        if delayMs > 0 { try? await Task.sleep(for: .milliseconds(delayMs)) }
    }
}

private let noop: @Sendable () async -> Void = {}

@Suite struct BrokerTests {
    let list = UUID()

    @Test func previewGetsNilWhenFull() async {
        let broker = StreamConnectionBroker()
        await broker.setLimit(1, playlistID: list)
        let play = await broker.acquire(.playback, playlistID: list, onRevoke: noop)
        #expect(play != nil)
        let preview = await broker.acquire(.preview, playlistID: list, onRevoke: noop)
        #expect(preview == nil)
        #expect(await broker.activeCount(playlistID: list) == 1)
    }

    @Test func downloadGetsNilWhenFull() async {
        let broker = StreamConnectionBroker()
        await broker.setLimit(1, playlistID: list)
        _ = await broker.acquire(.preview, playlistID: list, onRevoke: noop)
        #expect(await broker.acquire(.download, playlistID: list, onRevoke: noop) == nil)
    }

    @Test func playbackPreemptsPreview() async {
        let broker = StreamConnectionBroker()
        let log = RevokeLog()
        await broker.setLimit(1, playlistID: list)
        let preview = await broker.acquire(.preview, playlistID: list, onRevoke: revoker(log, "preview", delayMs: 50))
        #expect(preview != nil)
        let start = ContinuousClock.now
        let play = await broker.acquire(.playback, playlistID: list, onRevoke: noop)
        #expect(play?.purpose == .playback)
        #expect(ContinuousClock.now - start >= .milliseconds(45))
        #expect(await log.count("preview") == 1)
        #expect(await broker.activeCount(playlistID: list) == 1)
        // Återkallad lease släpps → no-op, platsen förblir uppspelningens.
        await broker.release(preview!)
        #expect(await broker.activeCount(playlistID: list) == 1)
    }

    @Test func playbackPreemptsOldestPlayback() async {
        let broker = StreamConnectionBroker()
        let log = RevokeLog()
        await broker.setLimit(1, playlistID: list)
        let first = await broker.acquire(.playback, playlistID: list, onRevoke: revoker(log, "first"))
        let second = await broker.acquire(.playback, playlistID: list, onRevoke: revoker(log, "second"))
        #expect(first != nil && second != nil)
        #expect(await log.count("first") == 1)
        #expect(await log.count("second") == 0)
        #expect(await broker.activeCount(playlistID: list) == 1)
    }

    @Test func victimOrderDownloadsThenPreviewsThenOldestPlayback() async {
        let broker = StreamConnectionBroker()
        let log = RevokeLog()
        await broker.setLimit(5, playlistID: list)
        _ = await broker.acquire(.playback, playlistID: list, onRevoke: revoker(log, "play1"))
        _ = await broker.acquire(.preview, playlistID: list, onRevoke: revoker(log, "prev1"))
        _ = await broker.acquire(.download, playlistID: list, onRevoke: revoker(log, "dl1"))
        _ = await broker.acquire(.preview, playlistID: list, onRevoke: revoker(log, "prev2"))
        _ = await broker.acquire(.download, playlistID: list, onRevoke: revoker(log, "dl2"))
        for _ in 0..<5 {
            #expect(await broker.acquire(.playback, playlistID: list, onRevoke: noop) != nil)
        }
        #expect(await log.order == ["dl1", "dl2", "prev1", "prev2", "play1"])
        #expect(await broker.activeCount(playlistID: list) == 5)
    }

    @Test func unknownLimitTreatedAsOne() async {
        let broker = StreamConnectionBroker()
        #expect(await broker.acquire(.preview, playlistID: list, onRevoke: noop) != nil)
        #expect(await broker.acquire(.preview, playlistID: list, onRevoke: noop) == nil)
        await broker.setLimit(nil, playlistID: list)
        #expect(await broker.acquire(.download, playlistID: list, onRevoke: noop) == nil)
    }

    @Test func limitTwoAllowsPlaybackPlusPreview() async {
        let broker = StreamConnectionBroker()
        let log = RevokeLog()
        await broker.setLimit(2, playlistID: list)
        #expect(await broker.acquire(.playback, playlistID: list, onRevoke: revoker(log, "play")) != nil)
        #expect(await broker.acquire(.preview, playlistID: list, onRevoke: revoker(log, "preview")) != nil)
        #expect(await broker.activeCount(playlistID: list) == 2)
        #expect(await broker.acquire(.preview, playlistID: list, onRevoke: noop) == nil)
        #expect(await log.order.isEmpty)
    }

    @Test func releaseFreesSlot() async {
        let broker = StreamConnectionBroker()
        await broker.setLimit(1, playlistID: list)
        let lease = await broker.acquire(.playback, playlistID: list, onRevoke: noop)!
        #expect(await broker.acquire(.preview, playlistID: list, onRevoke: noop) == nil)
        await broker.release(lease)
        #expect(await broker.activeCount(playlistID: list) == 0)
        await broker.release(lease) // dubbel release är no-op
        #expect(await broker.acquire(.preview, playlistID: list, onRevoke: noop) != nil)
        #expect(await broker.activeCount(playlistID: list) == 1)
    }

    @Test func perPlaylistIsolation() async {
        let broker = StreamConnectionBroker()
        let other = UUID()
        await broker.setLimit(1, playlistID: list)
        await broker.setLimit(1, playlistID: other)
        #expect(await broker.acquire(.playback, playlistID: list, onRevoke: noop) != nil)
        let p = await broker.acquire(.preview, playlistID: other, onRevoke: noop)
        #expect(p?.playlistID == other)
        #expect(await broker.acquire(.preview, playlistID: list, onRevoke: noop) == nil)
        #expect(await broker.activeCount(playlistID: list) == 1)
        #expect(await broker.activeCount(playlistID: other) == 1)
    }

    @Test func releaseDuringOwnRevokeIsFine() async {
        let broker = StreamConnectionBroker()
        await broker.setLimit(1, playlistID: list)
        let box = LeaseBox()
        let preview = await broker.acquire(.preview, playlistID: list, onRevoke: { [broker] in
            if let l = await box.lease { await broker.release(l) }
        })!
        await box.set(preview)
        let play = await broker.acquire(.playback, playlistID: list, onRevoke: noop)
        #expect(play != nil)
        #expect(await broker.activeCount(playlistID: list) == 1)
    }

    /// Deterministiskt utfall: A börjar återkalla P först; B ställs i kö (verifierat via
    /// waiterCount) innan P:s återkallning släpps. A får platsen och B återkallar sedan A.
    /// Varje lease återkallas exakt en gång.
    @Test func concurrentPlaybackAcquiresNeverRevokeTwice() async {
        let broker = StreamConnectionBroker()
        let log = RevokeLog()
        let gate = Gate()
        await broker.setLimit(1, playlistID: list)
        _ = await broker.acquire(.playback, playlistID: list, onRevoke: {
            await log.hit("P")
            await gate.wait()
        })
        let id = list
        let a = Task { await broker.acquire(.playback, playlistID: id, onRevoke: revoker(log, "A")) }
        #expect(await eventually { await log.count("P") == 1 })
        let b = Task { await broker.acquire(.playback, playlistID: id, onRevoke: revoker(log, "B")) }
        #expect(await eventually { await broker.waiterCount(playlistID: id) == 1 })
        await gate.open()
        let la = await a.value
        let lb = await b.value
        #expect(la != nil && lb != nil)
        #expect(await log.count("P") == 1)
        #expect(await log.count("A") == 1)
        #expect(await log.count("B") == 0)
        #expect(await log.order == ["P", "A"])
        #expect(await broker.activeCount(playlistID: list) == 1)
        #expect(await broker.waiterCount(playlistID: list) == 0)
    }

    /// En köad uppspelning som avbryts returnerar nil direkt och lämnar ingen spöklease.
    @Test func cancelledWaitingPlaybackGetsNil() async {
        let broker = StreamConnectionBroker()
        let log = RevokeLog()
        let gate = Gate()
        await broker.setLimit(1, playlistID: list)
        _ = await broker.acquire(.playback, playlistID: list, onRevoke: {
            await log.hit("P")
            await gate.wait()
        })
        let id = list
        let a = Task { await broker.acquire(.playback, playlistID: id, onRevoke: revoker(log, "A")) }
        #expect(await eventually { await log.count("P") == 1 })
        let b = Task { await broker.acquire(.playback, playlistID: id, onRevoke: revoker(log, "B")) }
        #expect(await eventually { await broker.waiterCount(playlistID: id) == 1 })
        b.cancel()
        #expect(await b.value == nil)
        #expect(await broker.waiterCount(playlistID: list) == 0)
        await gate.open()
        let la = await a.value
        #expect(la != nil)
        #expect(await log.count("A") == 0)
        #expect(await broker.activeCount(playlistID: list) == 1)
        await broker.release(la!)
        #expect(await broker.activeCount(playlistID: list) == 0)
        #expect(await broker.acquire(.preview, playlistID: list, onRevoke: noop) != nil)
    }

    /// En uppspelning som avbryts medan den återkallar får ingen lease; platsen blir ledig.
    @Test func cancelledRevokingPlaybackGetsNilAndFreesSlot() async {
        let broker = StreamConnectionBroker()
        let log = RevokeLog()
        let gate = Gate()
        await broker.setLimit(1, playlistID: list)
        _ = await broker.acquire(.preview, playlistID: list, onRevoke: {
            await log.hit("preview")
            await gate.wait()
        })
        let id = list
        let a = Task { await broker.acquire(.playback, playlistID: id, onRevoke: noop) }
        #expect(await eventually { await log.count("preview") == 1 })
        a.cancel()
        await gate.open()
        #expect(await a.value == nil)
        #expect(await broker.activeCount(playlistID: list) == 0)
        #expect(await broker.acquire(.preview, playlistID: list, onRevoke: noop) != nil)
        #expect(await broker.activeCount(playlistID: list) == 1)
    }

    @Test func cancelledCallerGetsNilImmediately() async {
        let broker = StreamConnectionBroker()
        let id = list
        let t = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await broker.acquire(.playback, playlistID: id, onRevoke: noop)
        }
        #expect(await t.value == nil)
        #expect(await broker.activeCount(playlistID: list) == 0)
    }

    @Test func revokeTimeoutFreesSlot() async {
        let broker = StreamConnectionBroker(revokeTimeout: .milliseconds(50))
        let done = Gate()
        await broker.setLimit(1, playlistID: list)
        _ = await broker.acquire(.preview, playlistID: list, onRevoke: {
            // Återvänder inte förrän testet är klart (långt efter tidsgränsen).
            await done.wait()
        })
        let start = ContinuousClock.now
        let play = await broker.acquire(.playback, playlistID: list, onRevoke: noop)
        #expect(play != nil)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await broker.activeCount(playlistID: list) == 1)
        await done.open()
    }
}

/// Engångsgrind: `wait()` blockerar tills `open()` anropats.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }
}

/// Pollar `condition` tills den är sann eller tidsgränsen (2 s) löper ut.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

private actor LeaseBox {
    var lease: StreamLease?
    func set(_ l: StreamLease) { lease = l }
}
