import CloudSync
import Foundation
import Sync
import SyncMapping

/// Varför en synkning misslyckades (för statusvisning och backoff).
enum SyncFailure: Equatable, Sendable {
    case noAccount, offline, quota, other

    /// Transporter kan kasta `SyncTransportFailure` för att tala om orsaken; `URLError` för nätfel tolkas också.
    static func classify(_ error: Error) -> SyncFailure {
        if let failure = error as? SyncTransportFailure {
            switch failure {
            case .noAccount: return .noAccount
            case .offline: return .offline
            case .quota: return .quota
            }
        }
        if let failure = error as? CloudSyncFailure {
            switch failure {
            case .noAccount: return .noAccount
            case .offline: return .offline
            case .quota: return .quota
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .dataNotAllowed,
                 .cannotFindHost:
                return .offline
            default:
                break
            }
        }
        return .other
    }
}

/// Fel en synkransport kan kasta för att ange orsaken.
enum SyncTransportFailure: Error, Equatable, Sendable {
    case noAccount, offline, quota
}

/// Tidtagning för strypning och backoff. I appen sover en `Task`; testerna kör en manuell version, så att inget
/// test sover på riktigt.
@MainActor
protocol SyncScheduling: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SyncTimer
}

@MainActor
final class SyncTimer {
    private var cancelHandler: (() -> Void)?
    init(cancel: @escaping () -> Void) { cancelHandler = cancel }
    func cancel() {
        cancelHandler?()
        cancelHandler = nil
    }
}

@MainActor
final class TaskSyncScheduler: SyncScheduling {
    init() {}

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SyncTimer {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            action()
        }
        return SyncTimer(cancel: { task.cancel() })
    }
}

/// Lagren (profilsessioner) meddelar synken om lokala ändringar via den här. Utan hanterare (standard) gör
/// `note` ingenting, och id:t byggs aldrig.
final class SyncChangeNotifier: @unchecked Sendable {
    // @unchecked Sendable: `handler` skyddas av `lock`.
    private let lock = NSLock()
    private var handler: (@Sendable (SyncRecordID) -> Void)?

    init() {}

    func setHandler(_ handler: (@Sendable (SyncRecordID) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func note(_ id: @autoclosure () -> SyncRecordID) {
        let current = lock.withLock { handler }
        current?(id())
    }
}
