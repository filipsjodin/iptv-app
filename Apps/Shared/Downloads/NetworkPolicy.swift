#if !os(tvOS)
import Foundation
import Network

/// Nätläget som nedladdningar bryr sig om. Ren värdetyp, så att beslutet kan testas utan `NWPath`.
struct NetworkStatus: Sendable, Equatable {
    var isOnline: Bool
    /// Wifi eller kabel, och inte en dyr uppkoppling (personlig surfzon över wifi räknas som mobildata).
    var isOnWifi: Bool

    static let offline = NetworkStatus(isOnline: false, isOnWifi: false)

    /// Översätter vägens egenskaper till nätläge. Ofullständig information är aldrig "wifi".
    static func make(isSatisfied: Bool, usesWifi: Bool, usesWired: Bool, isExpensive: Bool) -> NetworkStatus {
        guard isSatisfied else { return .offline }
        return NetworkStatus(isOnline: true, isOnWifi: (usesWifi || usesWired) && !isExpensive)
    }

    init(isOnline: Bool, isOnWifi: Bool) {
        self.isOnline = isOnline
        self.isOnWifi = isOnline && isOnWifi
    }
}

/// Nätövervakning för nedladdningshanteraren. Ett protokoll så att tester kan styra nätläget.
protocol NetworkPolicy: Sendable {
    /// Nuvarande läge.
    var status: NetworkStatus { get }
    /// Aktuellt läge direkt och därefter varje ändring.
    var changes: AsyncStream<NetworkStatus> { get }
}

/// `NWPathMonitor`-baserad övervakning. Tunn: all tolkning sker i `NetworkStatus.make`.
final class PathNetworkPolicy: NetworkPolicy, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var current = NetworkStatus.offline
    private var continuations: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(Self.status(of: path))
        }
        monitor.start(queue: DispatchQueue(label: "se.sjodin.iptv.network-policy"))
    }

    deinit { monitor.cancel() }

    var status: NetworkStatus {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var changes: AsyncStream<NetworkStatus> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let now = current
            lock.unlock()
            continuation.yield(now)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    private func update(_ new: NetworkStatus) {
        lock.lock()
        let changed = new != current
        current = new
        let targets = Array(continuations.values)
        lock.unlock()
        guard changed else { return }
        for continuation in targets { continuation.yield(new) }
    }

    private static func status(of path: NWPath) -> NetworkStatus {
        NetworkStatus.make(isSatisfied: path.status == .satisfied, usesWifi: path.usesInterfaceType(.wifi),
                           usesWired: path.usesInterfaceType(.wiredEthernet), isExpensive: path.isExpensive)
    }
}
#endif
