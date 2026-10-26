import Foundation
import Core

public struct ProgressKey: Hashable, Codable, Sendable {
    public var playlistID: UUID
    public var kind: ContentKind
    public var providerID: String
    /// Satt för avsnitt (`providerID` är då avsnittets id), annars nil.
    public var seriesProviderID: String?

    public init(playlistID: UUID, kind: ContentKind, providerID: String, seriesProviderID: String? = nil) {
        self.playlistID = playlistID
        self.kind = kind
        self.providerID = providerID
        self.seriesProviderID = seriesProviderID
    }
}

public struct WatchProgress: Codable, Equatable, Sendable {
    public var key: ProgressKey
    public var position: Double
    public var duration: Double?
    public var watched: Bool
    public var updatedAt: Date

    /// Kopia utan icke-ändliga värden (JSONEncoder kastar på dem och skulle blockera hela skrivningen).
    var sanitized: WatchProgress {
        var c = self
        if !c.position.isFinite { c.position = 0 }
        if let d = c.duration, !(d.isFinite && d > 0) { c.duration = nil }
        return c
    }

    public init(key: ProgressKey, position: Double, duration: Double?, watched: Bool, updatedAt: Date) {
        self.key = key
        self.position = position
        self.duration = duration
        self.watched = watched
        self.updatedAt = updatedAt
    }
}

public enum ProgressPolicy {
    public static let saveInterval: Duration = .seconds(10)
    public static let watchedFraction = 0.9
    public static let minimumResume: Double = 30
    public static let nextEpisodeLead: Double = 30
    public static let nextEpisodeCountdown = 10

    public static func progress(key: ProgressKey, position: Double, duration: Double?, now: Date) -> WatchProgress? {
        guard key.kind != .live else { return nil }
        let pos = position.isFinite ? max(0, position) : 0
        var dur: Double?
        if let duration, duration.isFinite, duration > 0 { dur = duration }
        let watched = dur.map { pos / $0 >= watchedFraction } ?? false
        return WatchProgress(key: key, position: pos, duration: dur, watched: watched, updatedAt: now)
    }

    public static func resumePosition(_ progress: WatchProgress?) -> Double? {
        guard let progress, !progress.watched, progress.position >= minimumResume else { return nil }
        return progress.position
    }
}
