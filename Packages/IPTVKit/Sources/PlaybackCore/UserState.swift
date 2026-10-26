import Foundation

public protocol UserStateStore: Sendable {
    func progress(for key: ProgressKey) -> WatchProgress?
    func save(_ progress: WatchProgress)
    /// Osedda titlar med resume-position, nyast först. För serier visas bara senaste avsnittet per serie
    /// (och serien utelämnas om det senaste avsnittet är sett).
    func continueWatching(playlistID: UUID, limit: Int) -> [WatchProgress]
    func lastWatchedEpisode(playlistID: UUID, seriesProviderID: String) -> WatchProgress?
    /// Alla poster för spellistan (filmer och avsnitt), i odefinierad ordning.
    func entries(playlistID: UUID) -> [WatchProgress]
    func remove(playlistID: UUID)
}

/// Gemensam logik över posterna (en per nyckel).
struct ProgressIndex {
    var entries: [ProgressKey: WatchProgress] = [:]

    init(_ list: [WatchProgress] = []) {
        for p in list { entries[p.key] = p.sanitized }
    }

    var list: [WatchProgress] { Array(entries.values) }

    mutating func save(_ p: WatchProgress, capacity: Int) {
        entries[p.key] = p.sanitized
        if entries.count > capacity {
            let drop = entries.values.sorted { $0.updatedAt < $1.updatedAt }.prefix(entries.count - capacity)
            for d in drop { entries[d.key] = nil }
        }
    }

    mutating func remove(playlistID: UUID) {
        for k in Array(entries.keys) where k.playlistID == playlistID { entries[k] = nil }
    }

    func continueWatching(playlistID: UUID, limit: Int) -> [WatchProgress] {
        guard limit > 0 else { return [] }
        var latestPerSeries: [String: WatchProgress] = [:]
        var others: [WatchProgress] = []
        for p in entries.values where p.key.playlistID == playlistID {
            if let series = p.key.seriesProviderID {
                if let cur = latestPerSeries[series], cur.updatedAt >= p.updatedAt { continue }
                latestPerSeries[series] = p
            } else {
                others.append(p)
            }
        }
        let candidates = others + Array(latestPerSeries.values)
        return Array(candidates
            .filter { !$0.watched && ProgressPolicy.resumePosition($0) != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit))
    }

    func entries(playlistID: UUID) -> [WatchProgress] {
        entries.values.filter { $0.key.playlistID == playlistID }
    }

    func lastWatchedEpisode(playlistID: UUID, seriesProviderID: String) -> WatchProgress? {
        entries.values
            .filter { $0.key.playlistID == playlistID && $0.key.seriesProviderID == seriesProviderID }
            .max { $0.updatedAt < $1.updatedAt }
    }
}

public final class InMemoryUserStateStore: UserStateStore, @unchecked Sendable {
    // @unchecked Sendable: allt muterbart state skyddas av `lock`.
    private let lock = NSLock()
    private var index = ProgressIndex()
    private let capacity: Int

    public init(capacity: Int = 1000) { self.capacity = capacity }

    public func progress(for key: ProgressKey) -> WatchProgress? { lock.withLock { index.entries[key] } }
    public func save(_ progress: WatchProgress) { lock.withLock { index.save(progress, capacity: capacity) } }
    public func continueWatching(playlistID: UUID, limit: Int) -> [WatchProgress] {
        lock.withLock { index.continueWatching(playlistID: playlistID, limit: limit) }
    }
    public func lastWatchedEpisode(playlistID: UUID, seriesProviderID: String) -> WatchProgress? {
        lock.withLock { index.lastWatchedEpisode(playlistID: playlistID, seriesProviderID: seriesProviderID) }
    }
    public func entries(playlistID: UUID) -> [WatchProgress] { lock.withLock { index.entries(playlistID: playlistID) } }
    public func remove(playlistID: UUID) { lock.withLock { index.remove(playlistID: playlistID) } }
}

public final class UserDefaultsUserStateStore: UserStateStore, @unchecked Sendable {
    // @unchecked Sendable: UserDefaults är trådsäkert men inte annoterat Sendable på alla plattformar;
    // `index` skyddas av `lock`.
    private let defaults: UserDefaults
    private let key: String
    private let capacity: Int
    private let lock = NSLock()
    private var index: ProgressIndex

    public init(defaults: UserDefaults, key: String = "userstate.progress.v1", capacity: Int = 500) {
        self.defaults = defaults
        self.key = key
        self.capacity = capacity
        // Skadad eller saknad data -> tomt lager.
        if let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode([WatchProgress].self, from: data) {
            self.index = ProgressIndex(list)
        } else {
            self.index = ProgressIndex()
        }
    }

    private func persist() {
        // Posterna är sanerade vid save/load, så kodningen kan inte falla på enskilda värden.
        // tvOS-gränsen för UserDefaults är ca 500 KB; 500 poster blir ca 100 KB.
        if let data = try? JSONEncoder().encode(index.list) { defaults.set(data, forKey: key) }
    }

    public func progress(for key: ProgressKey) -> WatchProgress? { lock.withLock { index.entries[key] } }
    public func save(_ progress: WatchProgress) {
        lock.withLock { index.save(progress, capacity: capacity); persist() }
    }
    public func continueWatching(playlistID: UUID, limit: Int) -> [WatchProgress] {
        lock.withLock { index.continueWatching(playlistID: playlistID, limit: limit) }
    }
    public func lastWatchedEpisode(playlistID: UUID, seriesProviderID: String) -> WatchProgress? {
        lock.withLock { index.lastWatchedEpisode(playlistID: playlistID, seriesProviderID: seriesProviderID) }
    }
    public func entries(playlistID: UUID) -> [WatchProgress] { lock.withLock { index.entries(playlistID: playlistID) } }
    public func remove(playlistID: UUID) {
        lock.withLock { index.remove(playlistID: playlistID); persist() }
    }
    /// Alla poster i lagret (alla spellistor). Används vid migrering av äldre globala nycklar.
    public func allEntries() -> [WatchProgress] { lock.withLock { index.list } }
}
