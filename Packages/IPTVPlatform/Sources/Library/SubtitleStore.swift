import Core
import Foundation
import GRDB
import Subtitles

/// Identifierar en titel för en viss profil och spellista (filmer och avsnitt; `providerID` är leverantörens id).
public struct SubtitleKey: Sendable, Hashable {
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

public struct StoredSubtitle: Sendable, Hashable, Identifiable {
    /// `file_id` hos OpenSubtitles.
    public var id: Int
    public var language: String
    public var release: String
    public var addedAt: Date
    public var fileURL: URL

    public init(id: Int, language: String, release: String, addedAt: Date, fileURL: URL) {
        self.id = id
        self.language = language
        self.release = release
        self.addedAt = addedAt
        self.fileURL = fileURL
    }
}

/// Teknisk information om en titel (ljud, undertexter, video) som spelaren observerat; visas på detaljsidan.
public struct TitleTechInfo: Sendable, Codable, Hashable {
    public var audioLanguages: [String]
    public var subtitleLanguages: [String]
    public var videoSummary: String?
    public var engine: String?
    public var recordedAt: Date

    public init(audioLanguages: [String], subtitleLanguages: [String], videoSummary: String? = nil,
                engine: String? = nil, recordedAt: Date) {
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.videoSummary = videoSummary
        self.engine = engine
        self.recordedAt = recordedAt
    }
}

public enum SubtitleStoreError: Error, Equatable, Sendable {
    /// Filen innehöll ingen text efter avkodning.
    case emptyFile
}

/// Lagring av nedladdade undertexter, tidsförskjutning och teknisk info. Filerna ligger som UTF-8 under
/// `<directory>/<profil>/<spellista>/<kind>-<providerID>/<fileID>.srt`; databasen sparar sökvägen relativt
/// `directory` (appens container-sökväg ändras mellan installationer).
public final class SubtitleStore: Sendable {
    let db: AppDatabase
    private let directory: URL
    /// Serialiserar filskrivning och städning så att `purgeOrphans` aldrig tar bort en fil som är på väg in.
    private let ioLock = NSLock()

    public init(db: AppDatabase, directory: URL) {
        self.db = db
        self.directory = directory
    }

    // MARK: - Filer

    /// Avkodar (UTF-8/UTF-16 med BOM, annars UTF-8, annars Windows-1252), skriver filen atomärt som UTF-8 och
    /// ersätter en tidigare rad med samma `fileID`. Allt sker i en transaktion: misslyckas filskrivningen finns
    /// ingen ny rad kvar.
    public func save(_ data: Data, result: OpenSubtitlesResult, for key: SubtitleKey) throws -> StoredSubtitle {
        let text = SubtitleDecoder.decode(data)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SubtitleStoreError.emptyFile }
        let utf8 = Data(text.utf8)
        let relative = Self.relativeDirectory(for: key) + "/\(result.id).srt"
        let url = fileURL(relative)
        let now = Date()
        try ioLock.withLock {
            try db.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO subtitleFile
                        (profileID, playlistID, kind, providerID, fileID, language, release, addedAt, path)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(profileID, playlistID, kind, providerID, fileID) DO UPDATE SET
                        language = excluded.language, release = excluded.release,
                        addedAt = excluded.addedAt, path = excluded.path
                    """, arguments: Self.arguments(
                        key, result.id, result.language, result.release, now.timeIntervalSince1970, relative))
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try utf8.write(to: url, options: .atomic)
            }
        }
        return StoredSubtitle(id: result.id, language: result.language, release: result.release, addedAt: now,
                              fileURL: url)
    }

    public func list(for key: SubtitleKey) throws -> [StoredSubtitle] {
        let rows = try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT fileID, language, release, addedAt, path FROM subtitleFile
                WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ?
                ORDER BY addedAt, fileID
                """, arguments: Self.arguments(key))
        }
        return rows.map { row in
            let path: String = row["path"]
            let id: Int = row["fileID"]
            let language: String = row["language"]
            let release: String = row["release"]
            let addedAt: Double = row["addedAt"]
            return StoredSubtitle(id: id, language: language, release: release,
                                  addedAt: Date(timeIntervalSince1970: addedAt), fileURL: fileURL(path))
        }
    }

    /// Tar bort raden och filen. Saknas filen redan är det inget fel.
    public func remove(fileID: Int, for key: SubtitleKey) throws {
        try ioLock.withLock {
            let storedPath: String? = try db.writer.write { db in
                let found = try String.fetchOne(db, sql: """
                    SELECT path FROM subtitleFile
                    WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ? AND fileID = ?
                    """, arguments: Self.arguments(key, fileID))
                try db.execute(sql: """
                    DELETE FROM subtitleFile
                    WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ? AND fileID = ?
                    """, arguments: Self.arguments(key, fileID))
                return found
            }
            if let storedPath { try removeFileIfPresent(fileURL(storedPath)) }
        }
    }

    /// Tar bort undertextfiler som inte längre har någon rad (t.ex. efter att en spellista raderats, då raderna
    /// försvinner via `ON DELETE CASCADE`) samt tomma kataloger. Returnerar antalet borttagna filer. Anropas vid
    /// start och efter att spellistor raderats.
    @discardableResult
    public func purgeOrphans() throws -> Int {
        try ioLock.withLock {
            let known: Set<String> = try db.writer.read { db in
                Set(try String.fetchAll(db, sql: "SELECT path FROM subtitleFile"))
            }
            var removed = 0
            for profile in try subdirectories(of: directory) {
                for playlist in try subdirectories(of: profile) {
                    for title in try subdirectories(of: playlist) {
                        for name in try FileManager.default.contentsOfDirectory(atPath: title.path) {
                            let relative = [profile.lastPathComponent, playlist.lastPathComponent,
                                            title.lastPathComponent, name].joined(separator: "/")
                            if !known.contains(relative) {
                                try removeFileIfPresent(title.appendingPathComponent(name))
                                removed += 1
                            }
                        }
                        try removeIfEmpty(title)
                    }
                    try removeIfEmpty(playlist)
                }
                try removeIfEmpty(profile)
            }
            return removed
        }
    }

    // MARK: - Tidsförskjutning

    /// Sekunder; positivt = undertexten visas senare. 0 om inget sparats.
    public func offset(for key: SubtitleKey) throws -> Double {
        let ms: Int? = try db.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT offsetMs FROM subtitleOffset
                WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ?
                """, arguments: Self.arguments(key))
        }
        return Double(ms ?? 0) / 1000
    }

    /// Klampas till −600…+600 s (0,1 s steg) via `SubtitleTrack.clampOffset`.
    /// `now` blir offsetens ändringstid (för synk, last-writer-wins).
    public func setOffset(_ seconds: Double, for key: SubtitleKey, now: Date = Date()) throws {
        let ms = Int((SubtitleTrack.clampOffset(seconds) * 1000).rounded())
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO subtitleOffset (profileID, playlistID, kind, providerID, offsetMs, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(profileID, playlistID, kind, providerID) DO UPDATE SET
                    offsetMs = excluded.offsetMs, updatedAt = excluded.updatedAt
                """, arguments: Self.arguments(key, ms, now.timeIntervalSince1970))
        }
    }

    /// Alla sparade förskjutningar för en profil, med ändringstid (för synk). Ordnade för determinism.
    public func offsets(profileID: UUID) throws -> [(key: SubtitleKey, offsetMs: Int, updatedAt: Date)] {
        let rows = try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT playlistID, kind, providerID, offsetMs, updatedAt FROM subtitleOffset
                WHERE profileID = ? ORDER BY playlistID, kind, providerID
                """, arguments: [profileID.uuidString])
        }
        var result: [(key: SubtitleKey, offsetMs: Int, updatedAt: Date)] = []
        for row in rows {
            let playlist: String = row["playlistID"]
            let kind: String = row["kind"]
            let provider: String = row["providerID"]
            let ms: Int = row["offsetMs"]
            let updated: Double = row["updatedAt"]
            guard let playlistID = UUID(uuidString: playlist), let contentKind = ContentKind(rawValue: kind) else {
                continue
            }
            result.append((
                key: SubtitleKey(profileID: profileID, playlistID: playlistID, kind: contentKind,
                                 providerID: provider),
                offsetMs: ms, updatedAt: Date(timeIntervalSince1970: updated)))
        }
        return result
    }

    /// Tar emot en förskjutning från en annan enhet. Ignoreras om den lokala är lika ny eller nyare. Annars sparas
    /// värdet (klampat) med fjärrens `updatedAt` (ingen bump till nu); undertextfiler rörs aldrig. Returnerar
    /// `true` om något skrevs. Saknas spellistan lokalt (främmande nyckel) skrivs inget och `false` returneras;
    /// anroparen kan försöka igen när spellistan finns.
    @discardableResult
    public func applyRemoteOffset(_ offsetMs: Int, key: SubtitleKey, updatedAt: Date) throws -> Bool {
        let clamped = min(max(offsetMs, -600_000), 600_000)
        let stamp = updatedAt.timeIntervalSince1970
        return try db.writer.write { db in
            let playlistExists = try Int.fetchOne(
                db, sql: "SELECT 1 FROM playlist WHERE id = ?", arguments: [key.playlistID.uuidString]) != nil
            guard playlistExists else { return false }
            let local: Double? = try Double.fetchOne(db, sql: """
                SELECT updatedAt FROM subtitleOffset
                WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ?
                """, arguments: Self.arguments(key))
            if let local, local >= stamp { return false }
            try db.execute(sql: """
                INSERT INTO subtitleOffset (profileID, playlistID, kind, providerID, offsetMs, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(profileID, playlistID, kind, providerID) DO UPDATE SET
                    offsetMs = excluded.offsetMs, updatedAt = excluded.updatedAt
                """, arguments: Self.arguments(key, clamped, stamp))
            return true
        }
    }

    // MARK: - Teknisk info

    public func recordTechInfo(_ info: TitleTechInfo, for key: SubtitleKey) throws {
        let json = String(decoding: try Self.makeEncoder().encode(info), as: UTF8.self)
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO titleTechInfo (profileID, playlistID, kind, providerID, json)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(profileID, playlistID, kind, providerID) DO UPDATE SET json = excluded.json
                """, arguments: Self.arguments(key, json))
        }
    }

    public func techInfo(for key: SubtitleKey) throws -> TitleTechInfo? {
        let json: String? = try db.writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT json FROM titleTechInfo
                WHERE profileID = ? AND playlistID = ? AND kind = ? AND providerID = ?
                """, arguments: Self.arguments(key))
        }
        guard let json else { return nil }
        return try Self.makeDecoder().decode(TitleTechInfo.self, from: Data(json.utf8))
    }

    // MARK: - Hjälpare

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

    /// Nyckelns fyra kolumner följda av eventuella extra värden, i den ordning SQL-satserna binder dem.
    private static func arguments(_ key: SubtitleKey, _ extra: (any DatabaseValueConvertible)?...)
        -> StatementArguments
    {
        var values: [(any DatabaseValueConvertible)?] = [
            key.profileID.uuidString, key.playlistID.uuidString, key.kind.rawValue, key.providerID,
        ]
        values.append(contentsOf: extra)
        return StatementArguments(values)
    }

    /// `providerID` procentkodas så att inga `/` eller `..` kan ta sig ur titelkatalogen.
    private static func relativeDirectory(for key: SubtitleKey) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let safe = key.providerID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "_"
        return "\(key.profileID.uuidString)/\(key.playlistID.uuidString)/\(key.kind.rawValue)-\(safe)"
    }

    private func fileURL(_ relative: String) -> URL {
        directory.appendingPathComponent(relative)
    }

    private func removeFileIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
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
