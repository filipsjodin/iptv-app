import Core
import Downloads
import Foundation
import GRDB

public struct DownloadArtwork: Sendable, Equatable {
    public var poster: URL?
    public var backdrop: URL?
    public var still: URL?

    public init(poster: URL? = nil, backdrop: URL? = nil, still: URL? = nil) {
        self.poster = poster
        self.backdrop = backdrop
        self.still = still
    }
}

public struct StoredDownload: Sendable, Equatable, Identifiable {
    public var key: DownloadKey
    public var snapshot: DownloadSnapshot
    public var state: DownloadState
    public var bytesWritten: Int64
    /// Absolut, byggd ur den relativa sökvägen. Bara satt för färdiga nedladdningar.
    public var fileURL: URL?
    public var artworkURLs: DownloadArtwork
    /// Får aldrig hämtas över mobildata, oavsett "bara wifi" (automatiskt köad).
    public var requiresWifi: Bool

    public var id: String {
        "\(key.profileID.uuidString)/\(key.playlistID.uuidString)/\(key.kind.rawValue)/\(key.providerID)"
    }

    public init(key: DownloadKey, snapshot: DownloadSnapshot, state: DownloadState, bytesWritten: Int64,
                fileURL: URL? = nil, artworkURLs: DownloadArtwork = DownloadArtwork(), requiresWifi: Bool = false) {
        self.key = key
        self.snapshot = snapshot
        self.state = state
        self.bytesWritten = bytesWritten
        self.fileURL = fileURL
        self.artworkURLs = artworkURLs
        self.requiresWifi = requiresWifi
    }
}

public enum DownloadStoreError: Error, Equatable, Sendable {
    /// Det finns ingen nedladdningsrad för nyckeln.
    case notFound
    /// Filen är mindre än förväntat minimum och markeras aldrig som färdig.
    case fileTooSmall(actual: Int64, required: Int64)
    /// `.completed` får bara sättas av `completeMoving`, som verifierar filen.
    case completionRequiresFile
}

/// Lagring av nedladdningar. Databasen håller ögonblicksbilden (utan FK mot katalogen), filerna ligger under
/// `<directory>/<DownloadPaths.relativeDirectory>/` och databasen sparar sökvägen relativt `directory`.
/// Mediafil, bildfiler och återupptagningsdata är undantagna från backup.
public final class DownloadStore: Sendable {
    let db: AppDatabase
    private let directory: URL
    /// Serialiserar filoperationer och städning så att `purgeOrphans` aldrig tar bort en fil som är på väg in.
    private let ioLock = NSLock()

    /// Tar bort en fil eller katalog. Kan ersättas i tester för att provocera borttagningsfel.
    private let removeItem: @Sendable (URL) throws -> Void

    public convenience init(db: AppDatabase, directory: URL) {
        self.init(db: db, directory: directory, removeItem: { try FileManager.default.removeItem(at: $0) })
    }

    init(db: AppDatabase, directory: URL, removeItem: @escaping @Sendable (URL) throws -> Void) {
        self.db = db
        self.directory = directory
        self.removeItem = removeItem
    }

    // MARK: - Rader

    /// Skapar en rad i `.queued`. Finns nyckeln redan returneras den befintliga raden oförändrad.
    @discardableResult
    public func insert(_ snapshot: DownloadSnapshot, key: DownloadKey,
                       requiresWifi: Bool = false) throws -> StoredDownload {
        let json = String(decoding: try Self.makeEncoder().encode(snapshot), as: UTF8.self)
        return try ioLock.withLock {
            try db.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO download
                        (profileID, playlistID, kind, providerID, snapshotJSON, state, progress, bytesWritten,
                         relativePath, addedAt, requiresWifi)
                    VALUES (?, ?, ?, ?, ?, ?, 0, 0, NULL, ?, ?)
                    ON CONFLICT(profileID, playlistID, kind, providerID) DO NOTHING
                    """, arguments: Self.arguments(
                        key, json, Self.encode(.queued).state, snapshot.addedAt.timeIntervalSince1970,
                        requiresWifi ? 1 : 0))
            }
            guard let stored = try fetch(key) else { throw DownloadStoreError.notFound }
            return stored
        }
    }

    public func list(profileID: UUID, playlistID: UUID?) throws -> [StoredDownload] {
        let rows: [Row] = try db.writer.read { db in
            if let playlistID {
                return try Row.fetchAll(db, sql: """
                    SELECT * FROM download WHERE profileID = ? AND playlistID = ?
                    ORDER BY addedAt, kind, providerID
                    """, arguments: [profileID.uuidString, playlistID.uuidString])
            }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM download WHERE profileID = ? ORDER BY addedAt, playlistID, kind, providerID
                """, arguments: [profileID.uuidString])
        }
        return try rows.map(stored(from:))
    }

    /// Alla rader för alla profiler, äldst först. För nedladdningshanteraren vid appstart (återanslutning till
    /// pågående överföringar); gränssnittet listar per profil med `list(profileID:playlistID:)`.
    public func listAll() throws -> [StoredDownload] {
        let rows: [Row] = try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM download ORDER BY addedAt, profileID, playlistID, kind, providerID")
        }
        return try rows.map(stored(from:))
    }

    public func download(for key: DownloadKey) throws -> StoredDownload? {
        try fetch(key)
    }

    /// Uppdaterar tillstånd och skrivna bytes. `.completed` kräver `completeMoving`; en redan färdig rad ändras
    /// inte (en sen förloppshändelse får inte backa den). Okänd nyckel är ingen operation.
    public func updateState(_ state: DownloadState, bytesWritten: Int64, for key: DownloadKey) throws {
        if state == .completed { throw DownloadStoreError.completionRequiresFile }
        let encoded = Self.encode(state)
        try ioLock.withLock {
            try db.writer.write { db in
                try db.execute(sql: """
                    UPDATE download SET state = ?, progress = ?, bytesWritten = ?
                    WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ? AND state != 'completed'
                    """, arguments: StatementArguments(
                        [encoded.state, encoded.progress, bytesWritten, key.profileID.uuidString,
                         key.playlistID.uuidString, key.kind.rawValue, key.providerID] as [(any DatabaseValueConvertible)?]))
            }
        }
    }

    public func totalBytes(profileID: UUID) throws -> Int64 {
        try db.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytesWritten), 0) FROM download WHERE profileID = ?",
                               arguments: [profileID.uuidString]) ?? 0
        }
    }

    // MARK: - Filer

    public func resumeData(for key: DownloadKey) throws -> Data? {
        try ioLock.withLock {
            let url = resumeURL(for: key)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
    }

    /// `nil` tar bort filen. Raden måste finnas så att inga föräldralösa filer skapas.
    public func setResumeData(_ data: Data?, for key: DownloadKey) throws {
        try ioLock.withLock {
            guard try rowExists(key) else { throw DownloadStoreError.notFound }
            let url = resumeURL(for: key)
            guard let data else { try removeFileIfPresent(url); return }
            try prepareDirectory(for: key)
            #if os(iOS) || os(tvOS)
            // Resume data innehåller den ursprungliga URL:en: skydda den tills enheten låsts upp första gången.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            try Self.excludeFromBackup(url)
        }
    }

    /// Verifierar storleken (minst `max(1, expectedMinBytes)`) innan något markeras färdigt. Är filen för liten
    /// försöker vi radera den (ett raderingsfel hindrar aldrig nästa steg), raden markeras alltid
    /// `failed(.badContent)` och `fileTooSmall` kastas. Annars flyttas filen till sin slutliga plats, undantas
    /// från backup och raden blir `completed`.
    ///
    /// Misslyckas flytt, backup-exkludering eller databasuppdatering markeras raden (best effort)
    /// `failed(.storage)` och felet kastas; en redan flyttad fil raderas inte. **Anroparen (nedladdnings-
    /// hanteraren) ska behandla varje kast som `failed(.storage)` och hämta om.**
    @discardableResult
    public func completeMoving(from temp: URL, for key: DownloadKey, expectedMinBytes: Int64) throws -> StoredDownload {
        try ioLock.withLock {
            guard let existing = try fetch(key) else {
                try? removeFileIfPresent(temp)
                throw DownloadStoreError.notFound
            }
            let actual: Int64
            do {
                actual = Int64(try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            } catch {
                try? removeFileIfPresent(temp)
                try? markFailed(.storage, key)
                throw error
            }
            let required = max(1, expectedMinBytes)
            guard actual >= required else {
                // Bästa möjliga radering; ett raderingsfel får inte hoppa över radmarkeringen.
                try? removeFileIfPresent(temp)
                try markFailed(.badContent, key)
                throw DownloadStoreError.fileTooSmall(actual: actual, required: required)
            }

            let relative = DownloadPaths.relativeDirectory(for: key) + "/"
                + DownloadPaths.fileName(container: existing.snapshot.container)
            let destination = fileURL(relative)
            do {
                try prepareDirectory(for: key)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: destination)
                }
                try Self.excludeFromBackup(destination)
                try db.writer.write { db in
                    try db.execute(sql: """
                        UPDATE download SET state = 'completed', progress = 1, bytesWritten = ?, relativePath = ?
                        WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ?
                        """, arguments: StatementArguments(
                            [actual, relative, key.profileID.uuidString, key.playlistID.uuidString,
                             key.kind.rawValue, key.providerID] as [(any DatabaseValueConvertible)?]))
                }
            } catch {
                // Den flyttade filen raderas inte: den kan ha ersatt en tidigare god fil.
                try? markFailed(.storage, key)
                throw error
            }
            try removeFileIfPresent(resumeURL(for: key))
            guard let stored = try fetch(key) else { throw DownloadStoreError.notFound }
            return stored
        }
    }

    public func saveArtwork(poster: Data?, backdrop: Data?, still: Data?, for key: DownloadKey) throws {
        try ioLock.withLock {
            guard try rowExists(key) else { throw DownloadStoreError.notFound }
            for (name, data) in [(Self.posterName, poster), (Self.backdropName, backdrop), (Self.stillName, still)] {
                guard let data else { continue }
                try prepareDirectory(for: key)
                let url = keyDirectory(for: key).appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                try Self.excludeFromBackup(url)
            }
        }
    }

    /// Tar bort raden och allt under nyckelns katalog (media, bilder, återupptagningsdata).
    public func remove(_ key: DownloadKey) throws {
        try ioLock.withLock {
            try db.writer.write { db in
                try db.execute(sql: """
                    DELETE FROM download WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ?
                    """, arguments: Self.arguments(key))
            }
            try removeFileIfPresent(keyDirectory(for: key))
        }
    }

    /// Tar bort kataloger utan rad (t.ex. efter att en spellista raderats via `ON DELETE CASCADE`), tomma
    /// föräldrakataloger, och markerar färdiga rader vars fil saknas som `failed(.storage)`.
    public func purgeOrphans() throws {
        try ioLock.withLock {
            let rows: [Row] = try db.writer.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM download")
            }
            var directories = Set<String>()
            var completed: [(key: DownloadKey, path: String)] = []
            for row in rows {
                guard let key = Self.key(from: row) else { continue }
                directories.insert(DownloadPaths.relativeDirectory(for: key))
                let state: String = row["state"]
                if state == "completed" {
                    let path: String? = row["relativePath"]
                    completed.append((key: key, path: path ?? ""))
                }
            }

            for profile in try subdirectories(of: directory) {
                for playlist in try subdirectories(of: profile) {
                    for kind in try subdirectories(of: playlist) {
                        for item in try subdirectories(of: kind) {
                            let relative = [profile.lastPathComponent, playlist.lastPathComponent,
                                            kind.lastPathComponent, item.lastPathComponent].joined(separator: "/")
                            if !directories.contains(relative) { try removeFileIfPresent(item) }
                        }
                        try removeIfEmpty(kind)
                    }
                    try removeIfEmpty(playlist)
                }
                try removeIfEmpty(profile)
            }

            for entry in completed {
                let present = !entry.path.isEmpty && FileManager.default.fileExists(atPath: fileURL(entry.path).path)
                if !present { try markFailed(.storage, entry.key) }
            }
        }
    }

    // MARK: - Hjälpare

    private static let posterName = "poster.img"
    private static let backdropName = "backdrop.img"
    private static let stillName = "still.img"
    private static let resumeName = "resume.data"

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    private static func arguments(_ key: DownloadKey, _ extra: (any DatabaseValueConvertible)?...) -> StatementArguments {
        var values: [(any DatabaseValueConvertible)?] = [
            key.profileID.uuidString, key.playlistID.uuidString, key.kind.rawValue, key.providerID,
        ]
        values.append(contentsOf: extra)
        return StatementArguments(values)
    }

    static func encode(_ state: DownloadState) -> (state: String, progress: Double) {
        switch state {
        case .queued: return ("queued", 0)
        case let .downloading(progress): return ("downloading", progress.isFinite ? min(max(progress, 0), 1) : 0)
        case let .paused(reason):
            switch reason {
            case .user: return ("paused.user", 0)
            case .connectionNeeded: return ("paused.connectionNeeded", 0)
            case .waitingForWifi: return ("paused.waitingForWifi", 0)
            case .lowDiskSpace: return ("paused.lowDiskSpace", 0)
            }
        case .completed: return ("completed", 1)
        case let .failed(failure): return ("failed.\(failure.rawValue)", 0)
        }
    }

    /// Okända värden (t.ex. från en nyare version) blir `failed(.unknown)` i stället för att fälla hela listan.
    static func decode(state: String, progress: Double) -> DownloadState {
        switch state {
        case "queued": return .queued
        case "downloading": return .downloading(progress: progress)
        case "paused.user": return .paused(.user)
        case "paused.connectionNeeded": return .paused(.connectionNeeded)
        case "paused.waitingForWifi": return .paused(.waitingForWifi)
        case "paused.lowDiskSpace": return .paused(.lowDiskSpace)
        case "completed": return .completed
        default:
            if state.hasPrefix("failed."), let failure = DownloadFailure(rawValue: String(state.dropFirst(7))) {
                return .failed(failure)
            }
            return .failed(.unknown)
        }
    }

    private static func key(from row: Row) -> DownloadKey? {
        let profile: String = row["profileID"]
        let playlist: String = row["playlistID"]
        let kind: String = row["kind"]
        let provider: String = row["providerID"]
        guard let profileID = UUID(uuidString: profile), let playlistID = UUID(uuidString: playlist),
              let contentKind = ContentKind(rawValue: kind) else { return nil }
        return DownloadKey(profileID: profileID, playlistID: playlistID, kind: contentKind, providerID: provider)
    }

    private func fetch(_ key: DownloadKey) throws -> StoredDownload? {
        let row: Row? = try db.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM download WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ?
                """, arguments: Self.arguments(key))
        }
        return try row.map(stored(from:))
    }

    private func rowExists(_ key: DownloadKey) throws -> Bool {
        try db.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT 1 FROM download WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ?
                """, arguments: Self.arguments(key)) != nil
        }
    }

    /// Används för `.storage`/`.badContent`: nollställer även bytes och sökväg så att `totalBytes` inte räknar
    /// en fil som inte längre är giltig.
    private func markFailed(_ failure: DownloadFailure, _ key: DownloadKey) throws {
        try db.writer.write { db in
            try db.execute(sql: """
                UPDATE download SET state = ?, progress = 0, bytesWritten = 0, relativePath = NULL
                WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ?
                """, arguments: StatementArguments(
                    [Self.encode(.failed(failure)).state, key.profileID.uuidString, key.playlistID.uuidString,
                     key.kind.rawValue, key.providerID] as [(any DatabaseValueConvertible)?]))
        }
    }

    private func stored(from row: Row) throws -> StoredDownload {
        guard let key = Self.key(from: row) else { throw DownloadStoreError.notFound }
        let json: String = row["snapshotJSON"]
        let snapshot = try Self.makeDecoder().decode(DownloadSnapshot.self, from: Data(json.utf8))
        let stateText: String = row["state"]
        let progress: Double = row["progress"]
        let bytes: Int64 = row["bytesWritten"]
        let path: String? = row["relativePath"]
        let state = Self.decode(state: stateText, progress: progress)
        let media: URL? = (state == .completed) ? path.map { self.fileURL($0) } : nil
        let dir = keyDirectory(for: key)
        func existing(_ name: String) -> URL? {
            let url = dir.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return StoredDownload(
            key: key, snapshot: snapshot, state: state, bytesWritten: bytes, fileURL: media,
            artworkURLs: DownloadArtwork(poster: existing(Self.posterName), backdrop: existing(Self.backdropName),
                                         still: existing(Self.stillName)),
            requiresWifi: ((row["requiresWifi"] as Int?) ?? 0) != 0)
    }

    private func fileURL(_ relative: String) -> URL {
        directory.appendingPathComponent(relative)
    }

    private func keyDirectory(for key: DownloadKey) -> URL {
        fileURL(DownloadPaths.relativeDirectory(for: key))
    }

    private func resumeURL(for key: DownloadKey) -> URL {
        keyDirectory(for: key).appendingPathComponent(Self.resumeName)
    }

    private func prepareDirectory(for key: DownloadKey) throws {
        let dir = keyDirectory(for: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.excludeFromBackup(dir)
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }

    private func removeFileIfPresent(_ url: URL) throws {
        do {
            try removeItem(url)
        } catch {
            let ns = error as NSError
            let missing = (ns.domain == NSCocoaErrorDomain && (ns.code == 4 || ns.code == 260))
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
            if !missing { throw error }
        }
    }

    private func subdirectories(of url: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        var result: [URL] = []
        for name in try fm.contentsOfDirectory(atPath: url.path) {
            let child = url.appendingPathComponent(name, isDirectory: true)
            var childIsDir: ObjCBool = false
            if fm.fileExists(atPath: child.path, isDirectory: &childIsDir), childIsDir.boolValue {
                result.append(child)
            }
        }
        return result
    }

    private func removeIfEmpty(_ url: URL) throws {
        let fm = FileManager.default
        if try fm.contentsOfDirectory(atPath: url.path).isEmpty { try fm.removeItem(at: url) }
    }
}
