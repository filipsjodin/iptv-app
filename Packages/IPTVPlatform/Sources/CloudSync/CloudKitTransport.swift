#if canImport(CloudKit)
import Foundation
import Sync
import SyncMapping

/// `SyncTransport` över `CKSyncEngine` (privat databas, zon `iptv`).
///
/// Att skapa transporten rör inte CloudKit: container och motor skapas först vid första `fetchChanges`/`push`,
/// och bara efter att kontostatus kontrollerats. Transporten skapas dessutom bara i synkbyggen (se
/// `AppModel.makeSyncTransport`), aldrig i standardbygget.
public final class CloudKitTransport: SyncTransport {
    private let core: CloudSyncCore

    public init(containerIdentifier: String = CloudKitConfiguration.defaultContainerIdentifier,
                stateDirectory: URL = CloudKitConfiguration.defaultStateDirectory(),
                now: @escaping @Sendable () -> Date = Date.init) {
        core = CloudSyncCore(containerIdentifier: containerIdentifier, stateDirectory: stateDirectory, now: now)
    }

    public func fetchChanges() async throws -> [SyncRecord] { try await core.fetchChanges() }
    public func push(_ records: [SyncRecord]) async throws { try await core.push(records) }
    public var remoteChanges: AsyncStream<Void> { core.remoteChanges }
}
#endif
