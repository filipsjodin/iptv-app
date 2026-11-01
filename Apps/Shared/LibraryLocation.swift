import Foundation
import Library

/// Var biblioteksdatabasen ligger. iOS: Application Support. tvOS: Caches, eftersom tvOS inte erbjuder
/// beständig lagring utöver cache; systemet kan rensa filen och då återskapas den tom.
enum LibraryLocation {
    static let fileName = "Library.sqlite"

    static func databaseURL() throws -> URL {
        let fm = FileManager.default
        #if os(tvOS)
        let dir = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #else
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #endif
        return dir.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Nedladdade undertexter. Samma platsregel som databasen (tvOS: Caches). Katalogen skapas vid första sparning.
    static func subtitlesDirectory() -> URL {
        let fm = FileManager.default
        #if os(tvOS)
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        #else
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        #endif
        return base.appendingPathComponent("Subtitles", isDirectory: true)
    }

    #if !os(tvOS)
    /// Nedladdade filer (iPhone/iPad). Application Support, så att systemet inte rensar dem. Katalogen skapas
    /// först när något sparas; på tvOS finns den inte alls.
    static func downloadsDirectory() -> URL {
        applicationSupport().appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Mellanlagring för färdighämtade filer innan de flyttas in (samma volym som `downloadsDirectory`).
    static func downloadsStagingDirectory() -> URL {
        applicationSupport().appendingPathComponent("DownloadsStaging", isDirectory: true)
    }

    private static func applicationSupport() -> URL {
        let fm = FileManager.default
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
    }
    #endif

    static func open() throws -> AppDatabase {
        let url = try databaseURL()
        #if os(tvOS)
        do {
            return try AppDatabase.onDisk(at: url)
        } catch {
            // Rensad eller trasig cachefil: börja om från en tom databas.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
            return try AppDatabase.onDisk(at: url)
        }
        #else
        return try AppDatabase.onDisk(at: url)
        #endif
    }
}
