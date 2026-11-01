#if !os(tvOS)
import Core
import Downloads
import Foundation
import Library
import Observation
import Playback
import PlaybackCore

/// Vyn bakom fliken Nedladdningar. Raderna härleds ur `DownloadManager.items` i minnet (ingen databas- eller
/// filåtkomst i `body`); det lediga utrymmet läses av `refresh()` utanför huvudtråden och cachas.
///
/// Barnprofil, eller ingen profil, ger alltid en tom lista. Bara den aktiva profilens rader visas. Inga
/// webbadresser, sökvägar eller servertexter når texterna: tillstånden är fasta, lokaliserade strängar.
@MainActor @Observable
final class DownloadsViewModel {
    // MARK: - Typer

    enum Action: Hashable, Sendable {
        case play, pause, resume, cancel, delete
    }

    /// Radens tillstånd i läsbar form (se `DownloadsViewModel.state(for:)`).
    enum RowState: Equatable, Sendable {
        case queued, downloading, pausedByUser, waitingForWifi, pausedForPlayback, lowDiskSpace, completed
        case failed(DownloadFailure)
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let key: DownloadKey
        var title: String
        var subtitle: String?
        var state: RowState
        var statusText: String
        /// 0...1 för pågående nedladdningar när förloppet är känt; annars `nil`.
        var progress: Double?
        var sizeText: String
        var canPlay: Bool
        var actions: [Action]
        var posterURL: URL?
    }

    struct Section: Identifiable, Equatable {
        let id: String
        var title: String
        var rows: [Row]
    }

    // MARK: - Tillstånd

    /// Det som spelas just nu (öppnar `playerCover`).
    var presented: PlayerPresentation?
    /// Fast, lokaliserad text att visa i en varning; `nil` när ingen visas.
    var message: String?
    private var freeBytesValue: Int64?

    @ObservationIgnored private let manager: DownloadManager
    @ObservationIgnored private let kids: @MainActor () -> Bool
    @ObservationIgnored private let freeBytes: @Sendable () -> Int64
    @ObservationIgnored private let profileID: @MainActor () -> UUID?
    @ObservationIgnored private let makeRequest: @MainActor (StoredDownload) async throws -> PlaybackRequest
    @ObservationIgnored private let nextEpisode: @MainActor (PlaybackRequest) -> (@MainActor () async -> PlaybackRequest?)?
    @ObservationIgnored private let remove: @MainActor (DownloadKey) async -> Void
    @ObservationIgnored private let playing: @MainActor () -> ProgressKey?

    /// - Parameter playing: nyckeln för det som spelas utanför fliken (för tester och framtida spelare); fliken
    ///   håller själv reda på det den startat (`presented`).
    init(manager: DownloadManager, kids: @escaping @MainActor () -> Bool, freeBytes: @escaping @Sendable () -> Int64,
         profileID: @escaping @MainActor () -> UUID?,
         request: @escaping @MainActor (StoredDownload) async throws -> PlaybackRequest,
         nextEpisode: @escaping @MainActor (PlaybackRequest) -> (@MainActor () async -> PlaybackRequest?)?,
         remove: @escaping @MainActor (DownloadKey) async -> Void,
         playing: @escaping @MainActor () -> ProgressKey? = { nil }) {
        self.manager = manager
        self.kids = kids
        self.freeBytes = freeBytes
        self.profileID = profileID
        self.makeRequest = request
        self.nextEpisode = nextEpisode
        self.remove = remove
        self.playing = playing
    }

    /// Kopplar mot appmodellen.
    convenience init(model: AppModel, manager: DownloadManager,
                     freeBytes: @escaping @Sendable () -> Int64 = DownloadsViewModel.deviceFreeBytes,
                     playing: @escaping @MainActor () -> ProgressKey? = { nil }) {
        self.init(manager: manager, kids: { [unowned model] in model.kidsRestricted }, freeBytes: freeBytes,
                  profileID: { [unowned model] in model.activeProfile?.profile.id },
                  request: { [unowned model] in try await model.offlineRequest(for: $0) },
                  nextEpisode: { [unowned model] in model.offlineNextEpisodeProvider(for: $0) },
                  remove: { [unowned model] in await model.removeDownload($0) },
                  playing: playing)
    }

    /// Ledigt utrymme på appens volym.
    nonisolated static func deviceFreeBytes() -> Int64 {
        DownloadManager.availableBytes(at: FileManager.default.temporaryDirectory)
    }

    // MARK: - Läsning

    /// Den aktiva, icke-barn-profilens nedladdningar.
    private var visibleItems: [StoredDownload] {
        guard !kids(), let profile = profileID() else { return [] }
        return manager.items.filter { $0.key.profileID == profile && $0.key.kind != .live }
    }

    var isEmpty: Bool { visibleItems.isEmpty }

    /// Pågående överst, sedan filmer, sedan serier (en sektion per serie och säsong).
    var sections: [Section] {
        let items = visibleItems
        let protected = protectedKeys(items)
        func row(_ item: StoredDownload) -> Row { Self.row(for: item, protected: protected.contains(item.key)) }

        var result: [Section] = []
        let active = items.filter { $0.state != .completed }
            .sorted { ($0.snapshot.addedAt, $0.id) < ($1.snapshot.addedAt, $1.id) }
        if !active.isEmpty {
            result.append(Section(id: "active", title: String(localized: "In progress"), rows: active.map(row)))
        }

        let done = items.filter { $0.state == .completed }
        let movies = done.filter { $0.key.kind == .movie }.sorted(by: Self.byTitle)
        if !movies.isEmpty {
            result.append(Section(id: "movies", title: String(localized: "Movies"), rows: movies.map(row)))
        }

        let episodes = done.filter { $0.key.kind == .series }
        var groups: [SeriesGroup: [StoredDownload]] = [:]
        for episode in episodes {
            let s = episode.snapshot
            let group = SeriesGroup(seriesID: s.seriesProviderID ?? episode.key.providerID,
                                    seriesTitle: s.seriesTitle ?? s.title, season: s.season ?? 0)
            groups[group, default: []].append(episode)
        }
        for group in groups.keys.sorted() {
            let rows = (groups[group] ?? []).sorted {
                ($0.snapshot.episode ?? 0, $0.id) < ($1.snapshot.episode ?? 0, $1.id)
            }
            result.append(Section(id: "series/\(group.seriesID)/\(group.season)", title: group.title,
                                  rows: rows.map(row)))
        }
        return result
    }

    private struct SeriesGroup: Hashable, Comparable {
        let seriesID: String
        let seriesTitle: String
        let season: Int

        var title: String {
            season > 0 ? String(localized: "\(seriesTitle) · Season \(season)") : seriesTitle
        }

        static func < (a: SeriesGroup, b: SeriesGroup) -> Bool {
            let t = a.seriesTitle.localizedCaseInsensitiveCompare(b.seriesTitle)
            if t != .orderedSame { return t == .orderedAscending }
            return (a.seriesID, a.season) < (b.seriesID, b.season)
        }
    }

    private static func byTitle(_ a: StoredDownload, _ b: StoredDownload) -> Bool {
        let t = a.snapshot.title.localizedCaseInsensitiveCompare(b.snapshot.title)
        return t == .orderedSame ? a.id < b.id : t == .orderedAscending
    }

    /// Använt utrymme för den aktiva profilens nedladdningar.
    var totalSizeText: String {
        let size = Self.sizeString(visibleItems.reduce(Int64(0)) { $0 + max(0, $1.bytesWritten) })
        return String(localized: "\(size) used")
    }

    /// Ledigt utrymme på enheten; tomt tills `refresh()` körts.
    var freeSpaceText: String {
        guard let freeBytesValue else { return "" }
        let size = Self.sizeString(freeBytesValue)
        return String(localized: "\(size) free")
    }

    /// Läser det lediga utrymmet utanför huvudtråden.
    func refresh() async {
        let read = freeBytes
        let value = await Task.detached(priority: .utility) { read() }.value
        freeBytesValue = max(0, value)
    }

    // MARK: - Åtgärder

    func perform(_ action: Action, on row: Row) async {
        guard !kids(), profileID() == row.key.profileID,
              let item = manager.items.first(where: { $0.key == row.key }) else { return }
        switch action {
        case .play:
            await play(item)
        case .pause:
            await manager.pause(row.key)
        case .resume:
            await manager.resume(row.key)
        case .cancel, .delete:
            guard !protectedKeys(visibleItems).contains(row.key) else {
                message = String(localized: "Stop playback before deleting this download.")
                return
            }
            await remove(row.key)
        }
    }

    private func play(_ item: StoredDownload) async {
        guard presented == nil else { return }
        do {
            let request = try await makeRequest(item)
            guard presented == nil else { return }
            presented = PlayerPresentation(request: request, nextEpisodeProvider: nextEpisode(request))
        } catch {
            message = UserFacingError.message(for: error)
        }
    }

    /// Rader som inte får raderas nu: det som spelas, och (eftersom nästa avsnitt kan ha tagit över) övriga
    /// avsnitt i samma serie medan spelaren är öppen.
    private func protectedKeys(_ items: [StoredDownload]) -> Set<DownloadKey> {
        var keys = Set<ProgressKey>()
        if let current = presented?.request.key { keys.insert(current) }
        if let external = playing() { keys.insert(external) }
        guard !keys.isEmpty else { return [] }
        var result = Set<DownloadKey>()
        for item in items {
            let progress = AppModel.offlineProgressKey(for: item)
            let sameSeries = item.key.kind == .series && keys.contains {
                $0.kind == .series && $0.playlistID == progress.playlistID && $0.seriesProviderID != nil
                    && $0.seriesProviderID == progress.seriesProviderID
            }
            if keys.contains(progress) || sameSeries { result.insert(item.key) }
        }
        return result
    }

    // MARK: - Rader

    static func state(for state: DownloadState) -> RowState {
        switch state {
        case .queued: .queued
        case .downloading: .downloading
        case .completed: .completed
        case let .failed(failure): .failed(failure)
        case let .paused(reason):
            switch reason {
            case .user: .pausedByUser
            case .connectionNeeded: .pausedForPlayback
            case .waitingForWifi: .waitingForWifi
            case .lowDiskSpace: .lowDiskSpace
            }
        }
    }

    static func statusText(for state: RowState) -> String {
        switch state {
        case .queued: String(localized: "Queued")
        case .downloading: String(localized: "Downloading")
        case .pausedByUser: String(localized: "Paused")
        case .waitingForWifi: String(localized: "Waiting for Wi-Fi")
        case .pausedForPlayback: String(localized: "Paused – playback in progress")
        case .lowDiskSpace: String(localized: "Out of space")
        case .completed: String(localized: "Downloaded")
        case let .failed(failure):
            switch failure {
            case .badStatus: String(localized: "The server rejected the download")
            case .badContent: String(localized: "The file was not a valid video")
            case .noSpace: String(localized: "Out of space")
            case .storage: String(localized: "The file could not be saved")
            case .expired: String(localized: "The download has expired")
            case .network: String(localized: "Network error")
            case .unknown: String(localized: "The download failed")
            }
        }
    }

    static func actions(for state: RowState, canPlay: Bool, protected: Bool) -> [Action] {
        var result: [Action]
        switch state {
        case .completed: result = canPlay ? [.play, .delete] : [.delete]
        case .queued, .downloading: result = [.pause, .cancel]
        case .pausedByUser, .failed: result = [.resume, .cancel]
        case .waitingForWifi, .pausedForPlayback, .lowDiskSpace: result = [.cancel]
        }
        if protected { result.removeAll { $0 == .delete || $0 == .cancel } }
        return result
    }

    static func row(for item: StoredDownload, protected: Bool = false) -> Row {
        let state = Self.state(for: item.state)
        let snapshot = item.snapshot
        let canPlay = item.state == .completed && item.fileURL != nil
        var subtitle: String?
        if item.key.kind == .series {
            var parts: [String] = []
            if let series = snapshot.seriesTitle { parts.append(series) }
            if let season = snapshot.season, let number = snapshot.episode { parts.append("S\(season):E\(number)") }
            subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        } else if let year = snapshot.year {
            subtitle = String(year)
        }
        var progress: Double?
        if case let .downloading(value) = item.state {
            progress = value.isFinite ? min(1, max(0, value)) : nil
        } else if state != .completed, let expected = snapshot.expectedBytes, expected > 0, item.bytesWritten > 0 {
            progress = min(1, Double(item.bytesWritten) / Double(expected))
        }
        return Row(id: item.id, key: item.key, title: snapshot.title, subtitle: subtitle, state: state,
                   statusText: statusText(for: state), progress: progress, sizeText: sizeText(for: item),
                   canPlay: canPlay, actions: actions(for: state, canPlay: canPlay, protected: protected),
                   posterURL: item.key.kind == .series
                       ? (item.artworkURLs.still ?? item.artworkURLs.poster) : item.artworkURLs.poster)
    }

    private static func sizeText(for item: StoredDownload) -> String {
        guard item.bytesWritten > 0 else { return "" }
        let written = sizeString(item.bytesWritten)
        if item.state != .completed, let expected = item.snapshot.expectedBytes, expected > item.bytesWritten {
            let total = sizeString(expected)
            return String(localized: "\(written) of \(total)")
        }
        return written
    }

    static func sizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
#endif
