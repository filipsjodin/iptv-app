import Foundation

public protocol SyncClock: Sendable {
    func now() -> Date
}

public struct SystemSyncClock: SyncClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Manuell klocka för tester.
public final class ManualSyncClock: SyncClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
