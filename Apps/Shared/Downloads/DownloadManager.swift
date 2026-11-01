#if !os(tvOS)
import Core
import Downloads
import Foundation
import Library
import Observation
import PlaybackCore

/// Sammanför kön (`DownloadQueue`), lagringen (`DownloadStore`), transporten, anslutningsvakten
/// (`StreamConnectionBroker`), nätet och det lediga utrymmet.
///
/// Konventioner (se `DownloadQueue`): `requestConnection` tar en lease per aktiv nedladdning, `releaseConnection`
/// släpper den, `connectionRevoked` ger bara `pause` eftersom leasen redan är tagen. Hanteraren kör högst en
/// nedladdning åt gången, så att resten av spellistans `max_connections` finns kvar för uppspelning.
///
/// Alla ändringar går genom en seriell kedja (`serialized`): ingen operation börjar förrän den förra är klar,
/// trots `await` mitt i. Därför får inga interna funktioner anropa `serialized` (det vore ett baklås); det gör
/// bara de publika ingångarna, transporthändelserna, brokerns `onRevoke` och återförsöksklockan.
///
/// Hemligheter: URL:en byggs i transporten och passerar aldrig hit. `secret` ger bara `PlaylistSecret` (som
/// själv skriver `<redacted>`) vidare till transporten per start; inget av det sparas, loggas eller hamnar i fel.
@MainActor @Observable
final class DownloadManager {
    /// Alla nedladdningar för alla profiler; gränssnittet filtrerar på profil. Observerbar.
    private(set) var items: [StoredDownload] = []

    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private let transport: any DownloadTransport
    @ObservationIgnored private let broker: StreamConnectionBroker
    @ObservationIgnored private let network: any NetworkPolicy
    @ObservationIgnored private let freeSpace: @Sendable () -> Int64
    @ObservationIgnored private let secret: @Sendable (UUID) async throws -> PlaylistSecret
    @ObservationIgnored private let retryInterval: Duration

    @ObservationIgnored private var queue = DownloadQueue(maxConcurrent: 1, wifiOnly: true)
    @ObservationIgnored private var handles: [DownloadKey: DownloadTaskHandle] = [:]
    /// Systemets pågående överföringar som hanteraren tar över vid start; startas inte om.
    @ObservationIgnored private var adopting: [DownloadKey: DownloadTaskHandle] = [:]
    @ObservationIgnored private var leases: [DownloadKey: StreamLease] = [:]
    /// Identifierar den lease som en `onRevoke` hör till, så att en sen återkallelse av en redan släppt lease ignoreras.
    @ObservationIgnored private var leaseTokens: [DownloadKey: UUID] = [:]
    @ObservationIgnored private var lastPersistedFraction: [DownloadKey: Double] = [:]
    /// Sant tills en lease kunnat tas igen efter en återkallelse eller nekad lease.
    @ObservationIgnored private var connectionBlocked = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    /// - Parameter retryInterval: hur ofta en nedladdning som väntar på anslutning eller utrymme försöker igen.
    init(store: DownloadStore, transport: any DownloadTransport, broker: StreamConnectionBroker,
         network: any NetworkPolicy, freeSpace: @escaping @Sendable () -> Int64,
         secret: @escaping @Sendable (UUID) async throws -> PlaylistSecret,
         retryInterval: Duration = .seconds(5)) {
        self.store = store
        self.transport = transport
        self.broker = broker
        self.network = network
        self.freeSpace = freeSpace
        self.secret = secret
        self.retryInterval = retryInterval
    }

    // MARK: - Publikt

    /// Läser sparade rader, tar över överföringar som systemet fortsatt och börjar lyssna på transport och nät.
    /// Anropas en gång vid appstart; senare anrop gör inget.
    func start() async {
        await serialized {
            guard !self.started else { return }
            self.started = true
            await self.load()
            self.listen()
        }
    }

    /// Avbryter hanterarens bakgrundsuppgifter (för tester). Pågående överföringar rörs inte.
    func stop() {
        eventsTask?.cancel()
        networkTask?.cancel()
        retryTask?.cancel()
        eventsTask = nil
        networkTask = nil
        retryTask = nil
    }

    /// Tillämpar nedladdningsinställningarna (bara wifi). Wifi-spärren omvärderas direkt.
    func configure(_ settings: DownloadSettings) async {
        await serialized { await self.run { $0.setWifiOnly(settings.wifiOnly) } }
    }

    /// Köar en nedladdning. En redan färdig eller pågående nedladdning ändras inte; en misslyckad eller
    /// användarpausad köas om.
    func enqueue(_ snapshot: DownloadSnapshot, key: DownloadKey) async throws {
        try await serializedThrowing {
            if self.item(for: key) != nil {
                await self.resumeLocked(key)
                return
            }
            let store = self.store
            let stored = try await offMain { try store.insert(snapshot, key: key) }
            if self.item(for: key) == nil { self.items.append(stored) }
            await self.retryConnection()
            await self.run { $0.enqueue(key) }
        }
    }

    /// Läser in bildfilerna som sparats efter att raden skapades, så att `items` pekar på dem. Rör inget annat.
    func refreshArtwork(_ key: DownloadKey) async {
        await serialized {
            let store = self.store
            guard let stored = try? await offMain({ try store.download(for: key) }) else { return }
            self.updateItem(key) { $0.artworkURLs = stored.artworkURLs }
        }
    }

    func pause(_ key: DownloadKey) async {
        await serialized { await self.run { $0.apply(.userPaused(key)) } }
    }

    func resume(_ key: DownloadKey) async {
        await serialized { await self.resumeLocked(key) }
    }

    /// Avbryter och tar bort nedladdningen, även en färdig (rad och filer).
    func cancel(_ key: DownloadKey) async {
        await serialized {
            await self.run { $0.apply(.userCancelled(key)) }
            self.items.removeAll { $0.key == key }
            self.lastPersistedFraction[key] = nil
            let store = self.store
            try? await offMain { try store.remove(key) }
        }
    }

    /// En uppspelning behöver spellistans anslutning: släpp våra leaser och pausa (resume data sparas).
    /// Uppspelningen kan också återkalla leasen själv via brokern; resultatet blir detsamma.
    func playbackWillNeedConnection(playlistID: UUID) async {
        await serialized {
            let keys = self.leases.keys.filter { $0.playlistID == playlistID }
            guard !keys.isEmpty else { return }
            for key in keys { await self.releaseLease(key) }
            self.connectionBlocked = true
            await self.process(.connectionRevoked)
        }
    }

    /// Återsynkar mot systemet: en bakgrundssession kan ha fortsatt utan lease medan appen var avstängd eller
    /// suspenderad. Överföringar som saknar lease får en (om en plats är ledig) eller stoppas.
    func applicationDidBecomeActive() async {
        await serialized {
            DownloadSessionEvents.shared.resetLatch()
            await self.reconcile(live: await self.transport.reattach())
            await self.retryConnection()
            await self.process(.spaceChanged(freeBytes: await self.freeBytes()))
        }
    }

    // MARK: - Seriell kedja

    private func serialized<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task<T, Never> { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task<Void, Never> { @MainActor in _ = await task.value }
        return await task.value
    }

    private func serializedThrowing<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = tail
        let task = Task<T, Error> { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task<Void, Never> { @MainActor in _ = await task.result }
        return try await task.value
    }

    // MARK: - Start och lyssnare

    private func load() async {
        let store = self.store
        try? await offMain { try store.purgeOrphans() }
        let rows = (try? await offMain { try store.listAll() }) ?? []
        items = rows

        await process(.networkChanged(allowsCellular: network.status.isOnWifi))
        await process(.spaceChanged(freeBytes: await freeBytes()))

        let open = rows.filter { row in
            switch row.state {
            case .completed, .failed: return false
            default: return true
            }
        }
        for handle in await transport.reattach() {
            if open.contains(where: { $0.key == handle.key }) {
                adopting[handle.key] = handle
            } else {
                await transport.cancel(handle)
            }
        }

        // Köa i ordning (övertagna först, så att de behåller sina platser) medan kön är spärrad, och släpp den
        // sedan så att allt schemaläggs på en gång.
        let adoptedFirst = open.filter { adopting[$0.key] != nil } + open.filter { adopting[$0.key] == nil }
        connectionBlocked = true
        await process(.connectionRevoked)
        for row in adoptedFirst {
            await run { $0.enqueue(row.key) }
            if row.state == .paused(.user) { await process(.userPaused(row.key)) }
        }
        connectionBlocked = false
        await process(.connectionGranted)

        // Övertagna överföringar som inte fick plats stoppas (resume data sparas).
        for (key, handle) in adopting {
            adopting[key] = nil
            await stopStray(handle)
        }
    }

    private func listen() {
        let events = transport.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.serialized { await self.handle(event) }
            }
        }
        let changes = network.changes
        networkTask = Task { [weak self] in
            for await status in changes {
                guard let self else { return }
                await self.serialized { await self.process(.networkChanged(allowsCellular: status.isOnWifi)) }
            }
        }
    }

    // MARK: - Transporthändelser

    private func handle(_ event: DownloadTransportEvent) async {
        switch event {
        case let .progress(handle, written, total):
            await handleProgress(handle, written: written, total: total)
        case let .finished(handle, staged, status, contentType):
            await handleFinished(handle, staged: staged, status: status, contentType: contentType)
        case let .failed(handle, failure, resumeData):
            await handleFailed(handle, failure: failure, resumeData: resumeData)
        case .backgroundEventsFinished:
            DownloadSessionEvents.shared.complete()
        }
    }

    private func handleProgress(_ handle: DownloadTaskHandle, written: Int64, total: Int64) async {
        let key = handle.key
        guard handles[key] == handle, let row = item(for: key) else { return }
        let expected = total > 0 ? total : (row.snapshot.expectedBytes ?? 0)
        let fraction = expected > 0 ? Double(written) / Double(expected) : 0
        await process(.progress(key, fraction))
        let state = queue.states[key]
        updateItem(key) {
            $0.bytesWritten = written
            if let state { $0.state = state }
        }
        // Förloppet sparas bara vid märkbar förändring (en rad per procent, inte per datapaket).
        let last = lastPersistedFraction[key] ?? -1
        if abs(fraction - last) >= 0.01, let state {
            lastPersistedFraction[key] = fraction
            let store = self.store
            try? await offMain { try store.updateState(state, bytesWritten: written, for: key) }
        }
    }

    private func handleFinished(_ handle: DownloadTaskHandle, staged: URL, status: Int, contentType: String?) async {
        let key = handle.key
        guard let row = item(for: key), row.state != .completed else {
            await discard(staged)
            return
        }
        // En nystartad överföring av samma titel (t.ex. efter omstart) behövs inte längre.
        if let current = handles.removeValue(forKey: key), current != handle { await transport.cancel(current) }
        lastPersistedFraction[key] = nil

        if let failure = DownloadResponseCheck.failure(status: status, contentType: contentType) {
            await discard(staged)
            await saveResumeData(nil, for: key)
            updateItem(key) { $0.bytesWritten = 0 }
            await process(.failed(key, failure))
            return
        }
        let store = self.store
        let minimum = DownloadResponseCheck.minimumBytes(expectedBytes: row.snapshot.expectedBytes)
        do {
            let stored = try await offMain { try store.completeMoving(from: staged, for: key, expectedMinBytes: minimum) }
            updateItem(key) { $0 = stored }
            await process(.finished(key))
        } catch let error as DownloadStoreError {
            switch error {
            case .fileTooSmall:
                updateItem(key) { $0.bytesWritten = 0 }
                await process(.failed(key, .badContent))
            case .notFound, .completionRequiresFile:
                // Raden försvann under tiden (avbruten): inget mer att göra.
                items.removeAll { $0.key == key }
                await process(.userCancelled(key))
            }
        } catch {
            // Varje annat kast från completeMoving betyder att filen inte kan användas: hämta om.
            updateItem(key) { $0.bytesWritten = 0 }
            await process(.failed(key, .storage))
        }
    }

    private func handleFailed(_ handle: DownloadTaskHandle, failure: DownloadFailure, resumeData: Data?) async {
        let key = handle.key
        // Sena fel från en uppgift vi redan stoppat eller bytt ut ändrar ingenting.
        guard handles[key] == handle else { return }
        handles[key] = nil
        lastPersistedFraction[key] = nil
        // Återupptagningsdata sparas bara efter nätfel; efter t.ex. ogiltiga uppgifter skulle den upprepa felet.
        await saveResumeData(failure == .network ? resumeData : nil, for: key)
        updateItem(key) { $0.bytesWritten = 0 }
        await process(.failed(key, failure))
    }

    // MARK: - Kön

    private func resumeLocked(_ key: DownloadKey) async {
        guard let row = item(for: key), row.state != .completed else { return }
        await retryConnection()
        if queue.states[key] != nil {
            await run { $0.apply(.userResumed(key)) }
        } else {
            await run { $0.enqueue(key) }
        }
    }

    private func process(_ event: DownloadEvent) async {
        await run { $0.apply(event) }
    }

    /// Ändrar kön, utför kommandona (och de följdhändelser de ger) och sparar tillståndsändringarna.
    private func run(_ mutate: (inout DownloadQueue) -> [DownloadCommand]) async {
        let before = queue.states
        var commands = mutate(&queue)
        while true {
            let followUps = await execute(commands)
            if followUps.isEmpty { break }
            commands = []
            for event in followUps { commands += queue.apply(event) }
        }
        await persist(from: before)
        refreshRetryTimer()
    }

    private func execute(_ commands: [DownloadCommand]) async -> [DownloadEvent] {
        var followUps: [DownloadEvent] = []
        var denied = Set<DownloadKey>()
        for command in commands {
            switch command {
            case let .requestConnection(key):
                let granted = await ensureLease(for: key)
                if !granted { denied.insert(key) }
            case let .start(key):
                if denied.contains(key) { continue }
                if let event = await startTransfer(key) { followUps.append(event) }
            case let .pause(key):
                await pauseTransfer(key)
            case let .cancel(key):
                await cancelTransfer(key)
            case let .releaseConnection(key):
                await releaseLease(key)
            }
        }
        if !denied.isEmpty {
            // Ingen ledig plats: behandla som återkallad anslutning och försök igen senare.
            connectionBlocked = true
            followUps.append(.connectionRevoked)
        }
        return followUps
    }

    private func ensureLease(for key: DownloadKey) async -> Bool {
        if leases[key] != nil { return true }
        let token = UUID()
        leaseTokens[key] = token
        let lease = await broker.acquire(.download, playlistID: key.playlistID) { [weak self] in
            await self?.leaseRevoked(key: key, token: token)
        }
        guard let lease else {
            leaseTokens[key] = nil
            return false
        }
        leases[key] = lease
        return true
    }

    private func releaseLease(_ key: DownloadKey) async {
        leaseTokens[key] = nil
        if let lease = leases.removeValue(forKey: key) { await broker.release(lease) }
    }

    /// Brokern tar platsen för en uppspelning. Leasen är redan borta; pausa överföringen (resume data sparas) och
    /// vänta på att platsen blir ledig igen.
    private func leaseRevoked(key: DownloadKey, token: UUID) async {
        await serialized {
            guard self.leaseTokens[key] == token else { return }
            self.leaseTokens[key] = nil
            self.leases[key] = nil
            self.connectionBlocked = true
            await self.process(.connectionRevoked)
        }
    }

    /// Returnerar en följdhändelse om starten misslyckas.
    private func startTransfer(_ key: DownloadKey) async -> DownloadEvent? {
        guard let row = item(for: key) else { return .userCancelled(key) }
        if let adopted = adopting.removeValue(forKey: key) {
            handles[key] = adopted
            return nil
        }
        let free = await freeBytes()
        guard DownloadSpace.canStart(expectedBytes: row.snapshot.expectedBytes, freeBytes: free,
                                     reserveBytes: queue.lowSpaceThresholdBytes) else {
            // Ryms inte: pausa med tydlig orsak utan att starta. En negativ siffra är alltid under tröskeln.
            return .spaceChanged(freeBytes: -1)
        }
        let value: PlaylistSecret
        do { value = try await secret(key.playlistID) } catch { return .failed(key, .unknown) }
        let store = self.store
        let resumeData = try? await offMain { try store.resumeData(for: key) }
        let request = DownloadTransportRequest(key: key, locator: row.snapshot.locator, secret: value,
                                               resumeData: resumeData, allowsCellular: !queue.wifiOnly)
        do {
            handles[key] = try await transport.start(request)
            // Resume data hör till den URL/de uppgifter den skapades med: använd den en gång, aldrig igen.
            if resumeData != nil { await saveResumeData(nil, for: key) }
            return nil
        } catch {
            return .failed(key, .unknown)
        }
    }

    private func pauseTransfer(_ key: DownloadKey) async {
        if let handle = handles.removeValue(forKey: key) ?? adopting.removeValue(forKey: key) {
            await saveResumeData(await transport.pause(handle), for: key)
        }
        // Utan lease får ingen överföring pågå, även om kön bara bad om en paus.
        await releaseLease(key)
    }

    private func cancelTransfer(_ key: DownloadKey) async {
        if let handle = handles.removeValue(forKey: key) ?? adopting.removeValue(forKey: key) {
            await transport.cancel(handle)
        }
    }

    // MARK: - Återsynk

    private func reconcile(live: [DownloadTaskHandle]) async {
        for handle in live {
            let key = handle.key
            if handles[key] == handle {
                if leases[key] != nil { continue }
                // Pågår utan lease: ta en, annars stoppa.
                if await ensureLease(for: key) { continue }
                handles[key] = nil
                await saveResumeData(await transport.pause(handle), for: key)
                connectionBlocked = true
                await process(.connectionRevoked)
            } else if queue.states[key] != nil {
                // Kön tror inte att den hämtar (pausad, köad eller klar) men systemet kör vidare.
                await stopStray(handle)
            } else {
                await transport.cancel(handle)
            }
        }
    }

    private func stopStray(_ handle: DownloadTaskHandle) async {
        await saveResumeData(await transport.pause(handle), for: handle.key)
    }

    // MARK: - Återförsök

    private func retryConnection() async {
        guard connectionBlocked else { return }
        connectionBlocked = false
        await process(.connectionGranted)
    }

    private var needsRetryTimer: Bool {
        connectionBlocked || queue.states.values.contains(.paused(.lowDiskSpace))
    }

    private func refreshRetryTimer() {
        guard retryTask == nil, needsRetryTimer else { return }
        let interval = retryInterval
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, await self.retryTick() else { return }
            }
        }
    }

    /// Sant om klockan ska fortsätta.
    private func retryTick() async -> Bool {
        await serialized {
            await self.retryConnection()
            if self.queue.states.values.contains(.paused(.lowDiskSpace)) {
                await self.process(.spaceChanged(freeBytes: await self.freeBytes()))
            }
            if self.needsRetryTimer { return true }
            self.retryTask = nil
            return false
        }
    }

    // MARK: - Lagring och rader

    private func persist(from before: [DownloadKey: DownloadState]) async {
        let store = self.store
        for (key, state) in queue.states {
            if let old = before[key], Self.kind(old) == Self.kind(state) { continue }
            if state == .completed { continue } // sparas av completeMoving
            var bytes = item(for: key)?.bytesWritten ?? 0
            var clearResume = false
            if case let .failed(failure) = state {
                bytes = 0
                // Efter nätfel finns nytt, användbart resume data; efter alla andra fel är det förgiftat.
                clearResume = failure != .network
            }
            let written = bytes
            updateItem(key) {
                $0.state = state
                $0.bytesWritten = written
            }
            // Ett uteblivet skrivfel syns som gammalt tillstånd efter omstart; hanteraren rättar till det då.
            try? await offMain { try store.updateState(state, bytesWritten: written, for: key) }
            if clearResume { try? await offMain { try store.setResumeData(nil, for: key) } }
        }
    }

    private static func kind(_ state: DownloadState) -> DownloadState {
        if case .downloading = state { return .downloading(progress: 0) }
        return state
    }

    private func saveResumeData(_ data: Data?, for key: DownloadKey) async {
        let store = self.store
        // Raden kan ha tagits bort under tiden; då finns inget att spara.
        try? await offMain { try store.setResumeData(data, for: key) }
    }

    private func discard(_ file: URL) async {
        try? await offMain { try FileManager.default.removeItem(at: file) }
    }

    private func item(for key: DownloadKey) -> StoredDownload? {
        items.first { $0.key == key }
    }

    private func updateItem(_ key: DownloadKey, _ change: (inout StoredDownload) -> Void) {
        guard let index = items.firstIndex(where: { $0.key == key }) else { return }
        change(&items[index])
    }

    private func freeBytes() async -> Int64 {
        let free = freeSpace
        return await Task.detached { free() }.value
    }

    /// Tillgängligt utrymme på volymen som `url` ligger på (för viktig användning). Kan det inte läsas ges ett
    /// så stort värde att nedladdningar inte spärras; ett verkligt utrymmesfel visas ändå som `noSpace`/`storage`.
    nonisolated static func availableBytes(at url: URL) -> Int64 {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }
}
#endif
