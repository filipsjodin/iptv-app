import Foundation
import Core

/// Identifierar en nedladdning inom (profil, spellista).
///
/// `kind` är `.movie` för filmer och `.series` för avsnitt; då är `providerID` *avsnittets* id (samma konvention
/// som `ProgressKey`/`SubtitleKey`). Serien hålls i `DownloadSnapshot.seriesProviderID`.
public struct DownloadKey: Sendable, Hashable {
    public var profileID: UUID
    public var playlistID: UUID
    public var kind: ContentKind
    public var providerID: String

    public init(profileID: UUID, playlistID: UUID, kind: ContentKind, providerID: String) {
        self.profileID = profileID
        self.playlistID = playlistID
        self.kind = kind
        self.providerID = providerID
    }
}

public enum PauseReason: Sendable, Equatable {
    case user, connectionNeeded, waitingForWifi, lowDiskSpace
}

/// Fasta felvärden. Aldrig servertext eller URL.
public enum DownloadFailure: String, Sendable, Equatable {
    case badStatus, badContent, noSpace, storage, expired, network, unknown
}

public enum DownloadState: Sendable, Equatable {
    case queued
    case downloading(progress: Double)
    case paused(PauseReason)
    case completed
    case failed(DownloadFailure)
}

/// Ögonblicksbild av titeln vid nedladdningen. Beror aldrig på `movie`/`episode`-rader i katalogen.
public struct DownloadSnapshot: Sendable, Equatable {
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var container: String?
    public var durationSeconds: Int?
    public var seriesProviderID: String?
    public var seriesTitle: String?
    /// Lagrar aldrig credentials (se `StreamLocator`).
    public var locator: StreamLocator
    public var expectedBytes: Int64?
    public var addedAt: Date

    public init(title: String, year: Int? = nil, season: Int? = nil, episode: Int? = nil, container: String? = nil,
                durationSeconds: Int? = nil, seriesProviderID: String? = nil, seriesTitle: String? = nil,
                locator: StreamLocator, expectedBytes: Int64? = nil, addedAt: Date = Date()) {
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode
        self.container = container
        self.durationSeconds = durationSeconds
        self.seriesProviderID = seriesProviderID
        self.seriesTitle = seriesTitle
        self.locator = locator
        self.expectedBytes = expectedBytes
        self.addedAt = addedAt
    }
}

public enum DownloadEvent: Sendable, Equatable {
    case progress(DownloadKey, Double)
    case finished(DownloadKey)
    case failed(DownloadKey, DownloadFailure)
    /// Anslutningen togs av en uppspelning.
    case connectionRevoked
    /// Anslutningen är ledig igen.
    case connectionGranted
    case networkChanged(allowsCellular: Bool)
    case userPaused(DownloadKey)
    case userResumed(DownloadKey)
    case userCancelled(DownloadKey)
    case spaceChanged(freeBytes: Int64)
}

public enum DownloadCommand: Sendable, Equatable {
    case start(DownloadKey), pause(DownloadKey), cancel(DownloadKey)
    case requestConnection(DownloadKey), releaseConnection(DownloadKey)
}
