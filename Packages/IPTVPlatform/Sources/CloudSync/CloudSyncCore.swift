#if canImport(CloudKit)
import CloudKit
import Foundation
import Sync

/// Motorn bakom `CloudKitTransport`: en `CKSyncEngine` (privat databas, zon `iptv`) och dess delegat.
///
/// Adapter mot `SyncTransport` (hämta/skicka): delegaten samlar hämtade poster i en buffert som `fetchChanges`
/// tömmer; `push` lägger posterna i en väntelista och köar `.saveRecord` hos motorn, som hämtar posterna via
/// `nextRecordZoneChangeBatch`.
///
/// Inget CloudKit-objekt skapas förrän `startedEngine()` körs (första `fetchChanges`/`push`), och transporten
/// skapas bara i synkbyggen. Kontostatus kontrolleras innan motorn startas.
final class CloudSyncCore: CKSyncEngineDelegate, @unchecked Sendable {
    // @unchecked Sendable: allt muterbart skyddas av `lock`.
    private struct EngineBox: @unchecked Sendable { let engine: CKSyncEngine }

    private let containerIdentifier: String
    private let stateURL: URL
    private let now: @Sendable () -> Date
    private let zoneID = CKRecordCoding.defaultZoneID()

    private let lock = NSLock()
    private var startTask: Task<EngineBox, Error>?
    private var pending: [CKRecord.ID: SyncRecord] = [:]
    private var serverRecords: [CKRecord.ID: CKRecord] = [:]
    private var fetched: [SyncRecord] = []
    private var sendFailure: Error?
    private var requeued = false
    private var suspended: CloudSyncFailure?
    private var stateWritesBlocked = false
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(containerIdentifier: String, stateDirectory: URL, now: @escaping @Sendable () -> Date) {
        self.containerIdentifier = containerIdentifier
        self.stateURL = stateDirectory.appendingPathComponent("CloudKitEngineState.json")
        self.now = now
    }

    // MARK: Transport

    func fetchChanges() async throws -> [SyncRecord] {
        let engine = try await startedEngine()
        do { try await engine.fetchChanges() } catch { throw Self.surface(error) }
        return lock.withLock {
            let out = fetched
            fetched = []
            return out
        }
    }

    func push(_ records: [SyncRecord]) async throws {
        let engine = try await startedEngine()
        // För stora poster kan inte synkas (CloudKit-gräns) och hoppas över i stället för att blockera allt.
        let ready = records.map(CKRecordCoding.quantized)
            .filter { ($0.payload?.count ?? 0) <= CKRecordCoding.maxPayloadBytes }
        guard !ready.isEmpty else { return }
        lock.withLock { sendFailure = nil }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        lock.withLock {
            for record in ready {
                let id = CKRecordCoding.recordID(for: record.id, zoneID: zoneID)
                pending[id] = record
                changes.append(.saveRecord(id))
            }
        }
        engine.state.add(pendingRecordZoneChanges: changes)
        // Konflikter köas om av delegaten; några varv räcker, resten tas vid nästa synk (smutsiga poster finns kvar).
        for _ in 0..<3 {
            lock.withLock { requeued = false }
            do { try await engine.sendChanges() } catch { throw Self.surface(error) }
            let failure: Error? = lock.withLock {
                let current = sendFailure
                sendFailure = nil
                return current
            }
            if let failure { throw Self.surface(failure) }
            if !lock.withLock({ requeued }) { break }
        }
        // Serverposter behövs bara för det som väntar på att skickas (ändringsmärket); släpp resten.
        lock.withLock { serverRecords = serverRecords.filter { pending[$0.key] != nil } }
    }

    var remoteChanges: AsyncStream<Void> {
        let token = UUID()
        return AsyncStream { continuation in
            lock.withLock { observers[token] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.observers[token] = nil }
            }
        }
    }

    private static func surface(_ error: Error) -> Error {
        CloudKitFailureMapping.failure(for: error) ?? error
    }

    private func notifyRemoteChanges() {
        let conts = lock.withLock { Array(observers.values) }
        for continuation in conts { continuation.yield() }
    }

    // MARK: Start

    private func startedEngine() async throws -> CKSyncEngine {
        if let reason = lock.withLock({ suspended }) { throw reason }
        let task: Task<EngineBox, Error> = lock.withLock {
            if let existing = startTask { return existing }
            let created = Task { try await self.makeEngine() }
            startTask = created
            return created
        }
        do {
            return try await task.value.engine
        } catch {
            lock.withLock { startTask = nil }
            throw Self.surface(error)
        }
    }

    private func makeEngine() async throws -> EngineBox {
        let container = CKContainer(identifier: containerIdentifier)
        let status = try await container.accountStatus()
        if let failure = CloudKitFailureMapping.failure(forAccountStatus: status) { throw failure }
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: loadState(), delegate: self)
        let engine = CKSyncEngine(configuration)
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        return EngineBox(engine: engine)
    }

    // MARK: Delegat

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            saveState(update.stateSerialization)
        case .accountChange(let change):
            handleAccountChange(change)
        case .fetchedDatabaseChanges(let changes):
            handleDatabaseChanges(changes, syncEngine)
        case .fetchedRecordZoneChanges(let changes):
            handleFetched(changes)
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, syncEngine)
        case .sentDatabaseChanges(let sent):
            if let failed = sent.failedZoneSaves.first {
                lock.withLock { sendFailure = sendFailure ?? failed.error }
            }
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = Array(syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }.prefix(400))
        // Köade ändringar utan väntande post (t.ex. efter omstart) tas bort ur motorns kö, annars fastnar de för alltid;
        // koordinatorn skickar om de smutsiga posterna.
        var orphans: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in changes {
            if case .saveRecord(let id) = change, !lock.withLock({ pending[id] != nil }) { orphans.append(change) }
        }
        if !orphans.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: orphans) }
        let live = changes.filter { !orphans.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: live) { [self] id in makeRecord(for: id) }
    }

    /// Posten som ska skickas. Utan väntande post (t.ex. efter omstart; koordinatorn skickar om de smutsiga) hoppas
    /// den över. Serverns senast kända post återanvänds så att ändringsmärket stämmer.
    private func makeRecord(for id: CKRecord.ID) -> CKRecord? {
        let (ours, base) = lock.withLock { (pending[id], serverRecords[id]) }
        guard let ours else { return nil }
        let seed = base.flatMap { $0.copy() as? CKRecord }
        return try? CKRecordCoding.encode(ours, zoneID: zoneID, into: seed)
    }

    private func handleFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        var out: [SyncRecord] = []
        for modification in changes.modifications {
            let record = modification.record
            lock.withLock { if pending[record.recordID] != nil { serverRecords[record.recordID] = record } }
            if let decoded = CKRecordCoding.decode(record) { out.append(decoded) }
        }
        // Raderingar ignoreras: appen raderar aldrig poster, gravstenar är vanliga poster.
        guard !out.isEmpty else { return }
        lock.withLock { fetched.append(contentsOf: out) }
        notifyRemoteChanges()
    }

    private func handleDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges,
                                       _ engine: CKSyncEngine) {
        // Zonen raderades (t.ex. användaren rensade iCloud-data för appen): skapa den på nytt. Lokal data rörs inte;
        // den laddas upp igen när koordinatorn gör en full uppladdning (av/på).
        guard changes.deletions.contains(where: { $0.zoneID == zoneID }) else { return }
        lock.withLock { serverRecords = [:] }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, _ engine: CKSyncEngine) {
        for saved in sent.savedRecords {
            let id = saved.recordID
            let stale: Bool = lock.withLock {
                guard let ours = pending[id] else {
                    serverRecords[id] = nil
                    return false
                }
                serverRecords[id] = saved
                if CKRecordCoding.decode(saved) == ours {
                    pending[id] = nil
                    serverRecords[id] = nil
                    return false
                }
                return true
            }
            // En nyare version lades i väntelistan medan den gamla skickades.
            if stale { engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)]) }
        }
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                resolveConflict(failure, engine)
            case .zoneNotFound:
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                lock.withLock { requeued = true }
            case .unknownItem:
                lock.withLock {
                    serverRecords[id] = nil
                    requeued = true
                }
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            default:
                lock.withLock { sendFailure = sendFailure ?? failure.error }
            }
        }
    }

    /// Hämta-slå ihop-spara: serverns version slås ihop med vår (`SyncMerge`) och skickas om om den skiljer sig
    /// från servern. Det sammanslagna resultatet levereras också till koordinatorn som en hämtad post.
    private func resolveConflict(_ failure: (record: CKRecord, error: CKError),
                                 _ engine: CKSyncEngine) {
        let id = failure.record.recordID
        guard let serverRecord = failure.error.serverRecord else {
            lock.withLock { sendFailure = sendFailure ?? failure.error }
            return
        }
        lock.withLock { serverRecords[id] = serverRecord }
        guard let server = CKRecordCoding.decode(serverRecord) else {
            // Serverns version är oläslig (nyare schema): skriv över med vår, med serverns ändringsmärke.
            lock.withLock { requeued = true }
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            return
        }
        let outcome: CloudConflictResolver.Outcome = lock.withLock {
            let result = CloudConflictResolver.resolve(server: server, ours: pending[id], now: now())
            pending[id] = result.needsResend ? result.merged : nil
            fetched.append(result.merged)
            requeued = requeued || result.needsResend
            return result
        }
        if outcome.needsResend { engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)]) }
        notifyRemoteChanges()
    }

    // MARK: Konto

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        let kind: AccountChangeKind
        switch change.changeType {
        case .signIn: kind = .signIn
        case .signOut: kind = .signOut
        case .switchAccounts: kind = .switchAccounts
        @unknown default: kind = .switchAccounts
        }
        switch AccountChangeAction.action(for: kind) {
        case .keepRunning:
            lock.withLock { suspended = nil }
        case .suspendNoAccount:
            lock.withLock { suspended = .noAccount }
        case .resetEngineStateAndSuspend:
            lock.withLock {
                suspended = .noAccount
                stateWritesBlocked = true
                pending = [:]
                serverRecords = [:]
                fetched = []
            }
            // Bara motorns token raderas; lokal data lämnas orörd.
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    // MARK: Motorns tillstånd

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveState(_ serialization: CKSyncEngine.State.Serialization) {
        if lock.withLock({ stateWritesBlocked }) { return }
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
        var url = stateURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
#endif
