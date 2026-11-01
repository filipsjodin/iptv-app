import Foundation
import Observation
import Sync
import SyncMapping

/// Samordnar synken: lokala ändringar → smutsiga poster → strypning → `push`; fjärrnotiser, start och förgrund →
/// `fetchChanges` → `SyncMapper.apply` → tillbaka i de riktiga lagren via `SyncStoreBridge`.
///
/// Utan transport (standardbygget) är koordinatorn `.unavailable` och varje metod gör ingenting: inga timers,
/// inga skrivningar, ingen läsning av lagren. Synk är dessutom AV tills användaren slår på den (`setEnabled`),
/// även när en transport finns. Avstängning slutar synka men raderar varken lokalt eller i molnet.
@MainActor @Observable
final class SyncCoordinator {
    enum Status: Equatable {
        case unavailable
        case off
        case idle(lastSync: Date?)
        case syncing
        case failed(SyncFailure)
    }

    /// Tider. Strypning: högst en push per `pushInterval`. Backoff: `backoffBase` · 2^(misslyckanden−1), högst `backoffCap`.
    struct Timing: Sendable {
        var pushInterval: TimeInterval = 60
        var backoffBase: TimeInterval = 5
        var backoffCap: TimeInterval = 15 * 60
        init() {}
    }

    static let enabledKey = "sync.enabled.v1"
    static let dirtyKey = "sync.dirty.v1"
    static let fullUploadKey = "sync.fullUpload.v1"
    static let lastSyncKey = "sync.lastSync.v1"

    private(set) var status: Status
    private(set) var isEnabled: Bool
    /// Första hämtningen sedan synken slogs på (eller appen startades) är klar. `ensureDefaultProfile` väntar på den.
    private(set) var initialPullDone = false
    /// Ökas varje gång fjärrändringar skrivits till de lokala lagren.
    private(set) var appliedRevision = 0

    @ObservationIgnored private let transport: (any SyncTransport)?
    @ObservationIgnored private let clock: any SyncClock
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bridge: SyncStoreBridge
    @ObservationIgnored private let scheduler: any SyncScheduling
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let backgroundRunner: any SyncBackgroundTaskRunning

    @ObservationIgnored private var dirty: Set<SyncRecordID> = []
    @ObservationIgnored private var needsFullUpload = false
    @ObservationIgnored private var touchedDuringPush: Set<SyncRecordID> = []
    @ObservationIgnored private var pushInFlight = false
    @ObservationIgnored private var lastPushAt: Date?
    @ObservationIgnored private var lastSync: Date?

    @ObservationIgnored private var wantPull = false
    @ObservationIgnored private var wantPush = false
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var pushTimer: SyncTimer?
    @ObservationIgnored private var retryTimer: SyncTimer?
    @ObservationIgnored private var started = false

    @ObservationIgnored private var initialPullWaitExpired = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var waiterTimers: [SyncTimer] = []

    init(transport: (any SyncTransport)?, clock: any SyncClock, defaults: UserDefaults, bridge: SyncStoreBridge,
         scheduler: (any SyncScheduling)? = nil, timing: Timing = Timing(),
         backgroundRunner: any SyncBackgroundTaskRunning = NoBackgroundTaskRunner()) {
        self.transport = transport
        self.clock = clock
        self.defaults = defaults
        self.bridge = bridge
        self.scheduler = scheduler ?? TaskSyncScheduler()
        self.timing = timing
        self.backgroundRunner = backgroundRunner
        if transport == nil {
            status = .unavailable
            isEnabled = false
        } else {
            let on = defaults.bool(forKey: Self.enabledKey)
            isEnabled = on
            let last = (defaults.object(forKey: Self.lastSyncKey) as? Double).map { Date(timeIntervalSince1970: $0) }
            lastSync = last
            status = on ? .idle(lastSync: last) : .off
            if on {
                dirty = Self.readDirty(defaults)
                needsFullUpload = defaults.bool(forKey: Self.fullUploadKey)
            }
        }
    }

    // MARK: Tillstånd

    /// Det finns en transport (synk är inbyggd), oavsett om användaren slagit på den.
    var isAvailable: Bool { transport != nil }
    private var isActive: Bool { transport != nil && isEnabled }
    /// Antal ändrade poster som väntar på push.
    var pendingChangeCount: Int { dirty.count }
    /// Appen ska vänta på första hämtningen innan den skapar en standardprofil.
    var isAwaitingInitialPull: Bool { isActive && !initialPullDone && !initialPullWaitExpired }

    // MARK: Livscykel

    /// Startar synken vid appstart (idempotent): lyssnar på fjärrnotiser och hämtar. Gör inget när synk är av.
    func start() {
        guard isActive, !started else { return }
        started = true
        startListening()
        kick(pull: true, push: hasPendingPush, ignoreBackoff: false)
    }

    /// Slår på eller av synk. På: full uppladdning och hämtning (väntar tills de är klara). Av: slutar synka,
    /// raderar ingenting.
    func setEnabled(_ on: Bool) async {
        guard transport != nil, on != isEnabled else { return }
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            needsFullUpload = true
            defaults.set(true, forKey: Self.fullUploadKey)
            initialPullDone = false
            initialPullWaitExpired = false
            started = true
            status = .idle(lastSync: lastSync)
            startListening()
            kick(pull: true, push: true, ignoreBackoff: true)
            await settle()
        } else {
            stop()
            status = .off
        }
    }

    /// Synkar nu: hämta, sedan pusha det som väntar. Väntar tills det är klart.
    func syncNow() async {
        guard isActive else { return }
        started = true
        startListening()
        kick(pull: true, push: true, ignoreBackoff: true)
        await settle()
    }

    /// Pushar det som väntar nu (appen går till bakgrunden, spelaren stängs) utan att vänta på strypningen.
    func flushNow() async {
        requestImmediatePush()
        await settle()
    }

    /// Som `flushNow` men utan att vänta (anropas från synkrona ställen som spelarens stängning).
    func requestImmediatePush() {
        guard isActive else { return }
        pushTimer?.cancel()
        pushTimer = nil
        guard hasPendingPush else { return }
        kick(pull: false, push: true, ignoreBackoff: true)
    }

    /// Appen kom till förgrunden: hämta det som hänt under tiden och pusha det som väntar.
    func sceneDidBecomeActive() {
        guard isActive else { return }
        if !started { start(); return }
        kick(pull: true, push: hasPendingPush, ignoreBackoff: true)
    }

    /// Appen går till bakgrunden: pusha direkt, inom en bakgrundsuppgift så att pushen hinner bli klar.
    func sceneDidEnterBackground() {
        requestImmediatePush()
        guard isActive, syncTask != nil else { return }
        backgroundRunner.run { [weak self] in await self?.settle() }
    }

    /// Väntar på att pågående arbete är klart (tester och `syncNow`).
    func settle() async {
        while let task = syncTask { await task.value }
    }

    // MARK: Lokala ändringar

    /// Något i lagren ändrades lokalt. Posten blir smutsig och pushas inom strypningsintervallet.
    func noteLocalChange(_ id: SyncRecordID) {
        guard isActive else { return }
        if dirty.insert(id).inserted { persistDirty() }
        if pushInFlight { touchedDuringPush.insert(id) }
        schedulePush()
    }

    /// Användaren raderar en profil (anropas före att lagren töms). Gravstenen sparas även när synk är av, så att
    /// profilen inte kan återuppstå när synk slås på.
    func profileWillBeDeleted(_ id: UUID) {
        guard transport != nil else { return }
        addDirty(bridge.recordProfileDeletion(id, now: clock.now()))
    }

    /// Användaren tar bort en spellista (anropas före att metadata och profiler töms).
    func playlistWillBeDeleted(_ id: UUID) {
        guard transport != nil else { return }
        addDirty(bridge.recordPlaylistDeletion(id, now: clock.now()))
    }

    /// Fail-closed: sant när profilen är PIN-skyddad på andra enheter men enheten saknar PIN-hash.
    func profileNeedsPin(_ id: UUID) -> Bool {
        guard transport != nil else { return false }
        return bridge.needsPin(id)
    }

    /// Avbryter lyssnare och timers (anropas när synk slås av). Raderar ingenting.
    func stop() {
        stopActivity()
    }

    /// Task 7 MÅSTE anropa denna när `KeychainProfilePinStore` har hash för profilen: låset hävs och profilen
    /// får `hasPin = true` lokalt. Inget annat lokalt flöde häver låset.
    func clearPinMissing(_ id: UUID) {
        guard transport != nil else { return }
        bridge.clearPinMissing(id)
    }

    /// Förskjutningar som väntat på en spellista prövas igen (efter att en fjärrspellista fått inloggning).
    func retryPendingOffsets() {
        guard transport != nil else { return }
        bridge.retryPendingOffsets()
    }

    private func addDirty(_ ids: Set<SyncRecordID>) {
        guard isActive, !ids.isEmpty else { return }
        dirty.formUnion(ids)
        if pushInFlight { touchedDuringPush.formUnion(ids) }
        persistDirty()
        schedulePush()
    }

    // MARK: Första hämtningen

    /// Väntar tills första hämtningen är klar, högst `timeout` sekunder (sedan fortsätter appen som vanligt).
    /// Återvänder direkt när synk inte är på eller redan väntat ut en gång.
    func waitForInitialPull(timeout: TimeInterval) async {
        guard isActive, !initialPullDone, !initialPullWaitExpired else { return }
        start()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
            let timer = scheduler.schedule(after: timeout) { [weak self] in
                guard let self else { return }
                self.initialPullWaitExpired = true
                self.releaseWaiters()
            }
            waiterTimers.append(timer)
        }
    }

    private func releaseWaiters() {
        let current = waiters
        waiters = []
        for timer in waiterTimers { timer.cancel() }
        waiterTimers = []
        for continuation in current { continuation.resume() }
    }

    // MARK: Motor

    private var hasPendingPush: Bool { needsFullUpload || !dirty.isEmpty }

    private func kick(pull: Bool, push: Bool, ignoreBackoff: Bool) {
        guard isActive else { return }
        wantPull = wantPull || pull
        wantPush = wantPush || push
        if ignoreBackoff {
            retryTimer?.cancel()
            retryTimer = nil
        }
        guard retryTimer == nil, syncTask == nil, wantPull || wantPush else { return }
        syncTask = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while isActive, wantPull || wantPush, retryTimer == nil {
            let doPull = wantPull
            let doPush = wantPush
            wantPull = false
            wantPush = false
            status = .syncing
            var pulled = false
            do {
                if doPull {
                    try await pull()
                    pulled = true
                }
                if doPush { try await push() }
                guard isActive else { break }
                failures = 0
                let stamp = clock.now()
                lastSync = stamp
                defaults.set(stamp.timeIntervalSince1970, forKey: Self.lastSyncKey)
                status = .idle(lastSync: stamp)
            } catch {
                guard isActive else { break }
                wantPull = wantPull || (doPull && !pulled)
                wantPush = wantPush || doPush
                failures += 1
                status = .failed(SyncFailure.classify(error))
                scheduleRetry()
            }
        }
        syncTask = nil
    }

    private func pull() async throws {
        guard let transport else { return }
        let records = try await transport.fetchChanges()
        guard isActive else { return }
        if !records.isEmpty { applyRemote(records) }
        bridge.retryPendingOffsets()
        initialPullDone = true
        releaseWaiters()
    }

    /// Huvudtråden gör bara tillämpningen (minnesoperationer och små skrivningar); nätet väntar vi på utanför.
    private func applyRemote(_ records: [SyncRecord]) {
        var state = bridge.loadState()
        let changes = SyncMapper.apply(records, to: &state, now: clock.now())
        bridge.writeBack(state, changes: changes)
        if !changes.dirty.isEmpty {
            dirty.formUnion(changes.dirty)
            persistDirty()
            wantPush = true
        }
        if !changes.isEmpty { appliedRevision += 1 }
    }

    private func push() async throws {
        guard let transport, hasPendingPush else { return }
        let state = bridge.loadState()
        let full = needsFullUpload
        let batch = dirty
        let records = SyncMapper.records(from: state, dirty: full ? nil : batch)
        pushInFlight = true
        touchedDuringPush = []
        defer { pushInFlight = false }
        if !records.isEmpty {
            try await transport.push(records)
            lastPushAt = clock.now()
        }
        guard isActive else { return }
        // Poster som ändrades under pushen står kvar som smutsiga.
        dirty.subtract(batch.subtracting(touchedDuringPush))
        touchedDuringPush = []
        if full {
            needsFullUpload = false
            defaults.removeObject(forKey: Self.fullUploadKey)
        }
        persistDirty()
    }

    private func schedulePush() {
        if retryTimer != nil {
            wantPush = true
            return
        }
        guard pushTimer == nil else { return }
        var wait: TimeInterval = 0
        if let last = lastPushAt {
            wait = max(0, timing.pushInterval - clock.now().timeIntervalSince(last))
        }
        pushTimer = scheduler.schedule(after: wait) { [weak self] in
            guard let self else { return }
            self.pushTimer = nil
            self.kick(pull: false, push: true, ignoreBackoff: false)
        }
    }

    private func scheduleRetry() {
        retryTimer?.cancel()
        let exponent = Double(max(0, failures - 1))
        let delay = min(timing.backoffCap, timing.backoffBase * pow(2, exponent))
        retryTimer = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.retryTimer = nil
            self.kick(pull: false, push: false, ignoreBackoff: false)
        }
    }

    private func startListening() {
        guard listenTask == nil, let transport else { return }
        let stream = transport.remoteChanges
        listenTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                self.kick(pull: true, push: false, ignoreBackoff: false)
            }
        }
    }

    private func stopActivity() {
        // Ett pågående anrop får bli klart, men dess resultat tillämpas inte (`isActive` kontrolleras efter varje väntan).
        listenTask?.cancel()
        listenTask = nil
        pushTimer?.cancel()
        pushTimer = nil
        retryTimer?.cancel()
        retryTimer = nil
        wantPull = false
        wantPush = false
        failures = 0
        started = false
        releaseWaiters()
    }

    // MARK: Lagring av smutsiga poster

    private func persistDirty() {
        if dirty.isEmpty {
            defaults.removeObject(forKey: Self.dirtyKey)
        } else if let data = try? JSONEncoder().encode(Array(dirty)) {
            defaults.set(data, forKey: Self.dirtyKey)
        }
    }

    private static func readDirty(_ defaults: UserDefaults) -> Set<SyncRecordID> {
        guard let data = defaults.data(forKey: dirtyKey),
              let ids = try? JSONDecoder().decode([SyncRecordID].self, from: data) else { return [] }
        return Set(ids)
    }
}
