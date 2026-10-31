import Foundation

/// Ren tillståndsmaskin för nedladdningskön (ingen I/O). Deterministisk FIFO-ordning.
///
/// Kommandokonvention (anslutningsleasen): när en rad börjar hämta ges `requestConnection(k)` följt av `start(k)`.
/// När en hämtande rad lämnar `downloading` (klar, misslyckad, avbruten, pausad) ges `releaseConnection(k)`.
/// Vid `connectionRevoked` har anslutningen redan tagits av uppspelningen, så bara `pause(k)` ges. Exekutorn
/// behandlar `requestConnection` som idempotent per nyckel.
///
/// Köordning: FIFO efter första `enqueue`. `userResumed` behåller radens ursprungliga plats (flyttar den inte
/// sist). `failed` gäller bara en hämtande rad; sena `failed` för pausade, köade eller okända rader ignoreras.
public struct DownloadQueue: Sendable {
    public private(set) var maxConcurrent: Int
    public private(set) var wifiOnly: Bool
    public private(set) var lowSpaceThresholdBytes: Int64

    private var order: [DownloadKey] = []
    private var stateByKey: [DownloadKey: DownloadState] = [:]
    private var connectionAvailable = true
    private var allowsCellular = true
    private var lowSpace = false
    private var lastFreeBytes: Int64?

    public init(maxConcurrent: Int = 1, wifiOnly: Bool = true, lowSpaceThresholdBytes: Int64 = 500 * 1024 * 1024) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.wifiOnly = wifiOnly
        self.lowSpaceThresholdBytes = max(0, lowSpaceThresholdBytes)
    }

    public var states: [DownloadKey: DownloadState] { stateByKey }

    @discardableResult
    public mutating func enqueue(_ key: DownloadKey) -> [DownloadCommand] {
        guard stateByKey[key] == nil else { return [] }
        order.append(key)
        stateByKey[key] = .queued
        return schedule()
    }

    @discardableResult
    public mutating func setMaxConcurrent(_ value: Int) -> [DownloadCommand] {
        maxConcurrent = max(1, value)
        return schedule()
    }

    /// Slår "bara wifi" på eller av och omvärderar kön direkt.
    @discardableResult
    public mutating func setWifiOnly(_ value: Bool) -> [DownloadCommand] {
        wifiOnly = value
        var out: [DownloadCommand] = []
        if blockedByNetwork { out += pauseDownloading(as: .waitingForWifi) }
        return out + schedule()
    }

    /// Ändrar tröskeln för lågt utrymme och omvärderar mot senast kända lediga utrymme.
    @discardableResult
    public mutating func setLowSpaceThreshold(_ bytes: Int64) -> [DownloadCommand] {
        lowSpaceThresholdBytes = max(0, bytes)
        guard let free = lastFreeBytes else { return [] }
        return apply(.spaceChanged(freeBytes: free))
    }

    public mutating func apply(_ event: DownloadEvent) -> [DownloadCommand] {
        var out: [DownloadCommand] = []
        switch event {
        case let .progress(key, p):
            if case let .downloading(old) = stateByKey[key] {
                stateByKey[key] = .downloading(progress: p.isFinite ? min(1, max(0, p)) : old)
            }
        case let .finished(key):
            out += leave(key, to: .completed)
        case let .failed(key, failure):
            if isDownloading(key) { out += leave(key, to: .failed(failure)) }
        case .connectionRevoked:
            connectionAvailable = false
            for key in order where isDownloading(key) {
                stateByKey[key] = .paused(.connectionNeeded)
                out.append(.pause(key))
            }
        case .connectionGranted:
            connectionAvailable = true
        case let .networkChanged(cellular):
            allowsCellular = cellular
            if blockedByNetwork { out += pauseDownloading(as: .waitingForWifi) }
        case let .userPaused(key):
            guard let s = stateByKey[key] else { return [] }
            switch s {
            case .downloading:
                stateByKey[key] = .paused(.user)
                out += [.pause(key), .releaseConnection(key)]
            case .queued, .paused:
                stateByKey[key] = .paused(.user)
            case .completed, .failed:
                return []
            }
        case let .userResumed(key):
            switch stateByKey[key] {
            case .paused, .failed: stateByKey[key] = .queued
            default: break
            }
        case let .userCancelled(key):
            guard let s = stateByKey[key] else { return [] }
            stateByKey[key] = nil
            order.removeAll { $0 == key }
            if s == .completed { return schedule() }
            out.append(.cancel(key))
            if case .downloading = s { out.append(.releaseConnection(key)) }
        case let .spaceChanged(free):
            lastFreeBytes = free
            lowSpace = free < lowSpaceThresholdBytes
            if lowSpace { out += pauseDownloading(as: .lowDiskSpace) }
        }
        return out + schedule()
    }

    // MARK: - Internt

    private func isDownloading(_ key: DownloadKey) -> Bool {
        if case .downloading = stateByKey[key] { return true }
        return false
    }

    private var blockedByNetwork: Bool { wifiOnly && !allowsCellular }

    private mutating func leave(_ key: DownloadKey, to new: DownloadState) -> [DownloadCommand] {
        guard let old = stateByKey[key], old != .completed else { return [] }
        stateByKey[key] = new
        if case .downloading = old { return [.releaseConnection(key)] }
        return []
    }

    private mutating func pauseDownloading(as reason: PauseReason) -> [DownloadCommand] {
        var out: [DownloadCommand] = []
        for key in order where isDownloading(key) {
            stateByKey[key] = .paused(reason)
            out += [.pause(key), .releaseConnection(key)]
        }
        return out
    }

    /// Kan en rad i det här tillståndet starta nu? Användarpausade och misslyckade rader startar aldrig själva.
    private func isEligible(_ state: DownloadState?) -> Bool {
        switch state {
        case .queued: return true
        case .paused(.connectionNeeded): return true
        case .paused(.waitingForWifi): return !blockedByNetwork
        case .paused(.lowDiskSpace): return !lowSpace
        default: return false
        }
    }

    private mutating func schedule() -> [DownloadCommand] {
        guard connectionAvailable, !blockedByNetwork, !lowSpace else { return [] }
        var active = order.filter { isDownloading($0) }.count
        var out: [DownloadCommand] = []
        for key in order where active < maxConcurrent && isEligible(stateByKey[key]) {
            stateByKey[key] = .downloading(progress: 0)
            out += [.requestConnection(key), .start(key)]
            active += 1
        }
        return out
    }
}
