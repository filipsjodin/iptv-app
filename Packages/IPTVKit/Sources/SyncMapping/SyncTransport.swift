import Foundation
import Sync

public protocol SyncTransport: Sendable {
    /// Poster som ändrats sedan förra lyckade hämtningen (transporten äger token).
    func fetchChanges() async throws -> [SyncRecord]
    func push(_ records: [SyncRecord]) async throws
    /// "Något nytt finns" från en annan enhet.
    var remoteChanges: AsyncStream<Void> { get }
}

public enum InMemorySyncError: Error, Equatable, Sendable { case injected }

/// Ordning som hämtade poster levereras i (för tester av omordning).
public enum SyncDeliveryOrder: Sendable, Equatable {
    case arrival
    case reversed
    case shuffled(seed: UInt64)
}

/// Delat "moln" som beter sig som CloudKit: en post per id (state-baserad sammanslagning med `SyncMerge`),
/// ett versionsnummer per ändring. Varje enhet får en egen `InMemorySyncTransport` med egen läsmarkör.
public final class InMemoryCloud: @unchecked Sendable {
    // @unchecked Sendable: allt muterbart skyddas av `lock`.
    private let lock = NSLock()
    private var entries: [SyncRecordID: (record: SyncRecord, version: Int)] = [:]
    private var version = 0
    private var observers: [UUID: (owner: UUID, cont: AsyncStream<Void>.Continuation)] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    public var currentVersion: Int { lock.withLock { version } }
    public var allRecords: [SyncRecord] { lock.withLock { entries.values.map(\.record) } }
    public func record(for id: SyncRecordID) -> SyncRecord? { lock.withLock { entries[id]?.record } }

    public func connect() -> InMemorySyncTransport { InMemorySyncTransport(cloud: self) }

    func changes(after cursor: Int) -> (records: [(SyncRecord, Int)], cursor: Int) {
        lock.withLock {
            let list = entries.values.filter { $0.version > cursor }
                .sorted { $0.version < $1.version }
                .map { ($0.record, $0.version) }
            return (list, version)
        }
    }

    /// Slår ihop in i molnet; returnerar om något ändrades. Oförändrad post (idempotent omsändning) höjer inte versionen.
    func push(_ records: [SyncRecord], from owner: UUID) {
        var changed = false
        lock.withLock {
            for r in records {
                let merged = SyncMerge.merge(local: entries[r.id]?.record, remote: r, now: now())
                if entries[r.id]?.record == merged { continue }
                version += 1
                entries[r.id] = (merged, version)
                changed = true
            }
        }
        if changed { notify(except: owner) }
    }

    func observe(owner: UUID) -> AsyncStream<Void> {
        let token = UUID()
        return AsyncStream { cont in
            lock.withLock { observers[token] = (owner, cont) }
            cont.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.observers[token] = nil }
            }
        }
    }

    private func notify(except owner: UUID) {
        let conts = lock.withLock { observers.values.filter { $0.owner != owner }.map(\.cont) }
        for c in conts { c.yield() }
    }
}

public final class InMemorySyncTransport: SyncTransport, @unchecked Sendable {
    // @unchecked Sendable: allt muterbart skyddas av `lock`.
    private let lock = NSLock()
    private let cloud: InMemoryCloud
    private let id = UUID()
    private var cursor = 0
    private var pushFailures = 0
    private var fetchFailures = 0
    private var order: SyncDeliveryOrder = .arrival
    private var delay: Duration?
    public private(set) var pushCount = 0
    public private(set) var fetchCount = 0

    public init(cloud: InMemoryCloud) { self.cloud = cloud }
    /// Eget moln; fler enheter ansluts med `another()`.
    public convenience init() { self.init(cloud: InMemoryCloud()) }

    public func another() -> InMemorySyncTransport { InMemorySyncTransport(cloud: cloud) }
    public var sharedCloud: InMemoryCloud { cloud }

    // MARK: Testkrokar

    public func failNextPushes(_ n: Int) { lock.withLock { pushFailures = n } }
    public func failNextFetches(_ n: Int) { lock.withLock { fetchFailures = n } }
    public func setDeliveryOrder(_ o: SyncDeliveryOrder) { lock.withLock { order = o } }
    public func setDelay(_ d: Duration?) { lock.withLock { delay = d } }
    /// Glöm läsmarkören (som en ny installation): nästa hämtning ger hela molnet.
    public func resetCursor() { lock.withLock { cursor = 0 } }

    // MARK: SyncTransport

    public func fetchChanges() async throws -> [SyncRecord] {
        let (fail, order, delay): (Bool, SyncDeliveryOrder, Duration?) = lock.withLock {
            fetchCount += 1
            if fetchFailures > 0 { fetchFailures -= 1; return (true, self.order, self.delay) }
            return (false, self.order, self.delay)
        }
        if let delay { try await Task.sleep(for: delay) }
        if fail { throw InMemorySyncError.injected }
        let start = lock.withLock { cursor }
        let result = cloud.changes(after: start)
        lock.withLock { cursor = max(cursor, result.cursor) }
        var records = result.records.map(\.0)
        switch order {
        case .arrival: break
        case .reversed: records.reverse()
        case .shuffled(let seed):
            var rng = SplitMix64(seed: seed &+ UInt64(result.cursor))
            records.shuffle(using: &rng)
        }
        return records
    }

    public func push(_ records: [SyncRecord]) async throws {
        let (fail, delay): (Bool, Duration?) = lock.withLock {
            pushCount += 1
            if pushFailures > 0 { pushFailures -= 1; return (true, self.delay) }
            return (false, self.delay)
        }
        if let delay { try await Task.sleep(for: delay) }
        if fail { throw InMemorySyncError.injected }
        cloud.push(records, from: id)
    }

    public var remoteChanges: AsyncStream<Void> { cloud.observe(owner: id) }
}

/// Seedbar slumpkälla (deterministiska tester).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
