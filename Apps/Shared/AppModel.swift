import Core
import Foundation
import Library
import Observation
import Providers
import Secrets

@MainActor @Observable
final class AppModel {
    var playlists: [Playlist] = []
    var counts: [UUID: [ContentKind: Int]] = [:]
    var importState: [UUID: ImportPhase] = [:]
    /// Lokaliserat, fast meddelande. Innehåller aldrig server, URL, användarnamn eller underliggande fel.
    var lastError: String?

    let store: LibraryStore
    private let credentials: CredentialStore
    private let http: HTTPClient
    @ObservationIgnored private let metadata: PlaylistMetadataStore
    private var importTasks: [UUID: Task<Void, Never>] = [:]

    init(store: LibraryStore, credentials: CredentialStore, http: HTTPClient, defaults: UserDefaults = .standard) {
        self.store = store
        self.credentials = credentials
        self.http = http
        self.metadata = PlaylistMetadataStore(defaults: defaults)
    }

    /// Produktionsuppsättning: databas på disk, Keychain och `URLSessionHTTPClient()` med paketets
    /// standardvärden (30 s per förfrågan, 600 s per resurs – räcker för stora kataloger).
    static func live() -> AppModel {
        let http = URLSessionHTTPClient()
        let credentials = KeychainCredentialStore()
        do {
            return AppModel(store: LibraryStore(db: try LibraryLocation.open()), credentials: credentials, http: http)
        } catch {
            // Sista utväg: en tillfällig databas så att appen ändå startar. Spellistorna återställs från
            // metadata i `load()`.
            // swiftlint:disable:next force_try
            let model = AppModel(store: LibraryStore(db: try! AppDatabase.inMemory()), credentials: credentials,
                                 http: http)
            model.lastError = String(localized: "The library could not be opened on this device.")
            return model
        }
    }

    func isImporting(_ id: UUID) -> Bool { importTasks[id] != nil }

    /// Laddar spellistorna. Spellistor som finns i metadata men saknas i databasen (t.ex. för att tvOS rensat
    /// cachen) läggs tillbaka och importeras om, förutsatt att hemligheten finns kvar; annars glöms de.
    func load() async {
        let restored = await restoreMissingPlaylists()
        await reloadPlaylists()
        // Spellistor som fanns i databasen innan metadata infördes.
        let known = Set(metadata.all().map(\.id))
        for p in playlists where !known.contains(p.id) { metadata.save(p) }
        for id in restored { startRefresh(id) }
    }

    /// Ordning: hemligheten i Keychain → raden i databasen → import. Misslyckas raden tas hemligheten bort igen.
    func addPlaylist(name: String, secret: PlaylistSecret) async {
        let kind: PlaylistSourceKind = switch secret {
        case .xtream: .xtream
        case .m3u: .m3u
        }
        let playlist = Playlist(name: name, kind: kind)
        let id = playlist.id
        let store = store, credentials = credentials

        do {
            try await offMain { try credentials.save(secret, for: id) }
        } catch {
            report(error)
            return
        }
        do {
            try await offMain { try store.upsertPlaylist(playlist) }
        } catch {
            try? await offMain(honorsCancellation: false) { try credentials.delete(for: id) }
            report(ImportError.storageFailed)
            return
        }
        metadata.save(playlist)
        await reloadPlaylists()
        await refresh(id)
    }

    /// Kör (om)import och väntar tills den är klar. Pågår redan en import för spellistan väntar vi in den.
    func refresh(_ id: UUID) async {
        await startRefresh(id).value
    }

    /// Startar en import (eller returnerar den som redan pågår) utan att vänta på den.
    @discardableResult
    func startRefresh(_ id: UUID) -> Task<Void, Never> {
        if let running = importTasks[id] { return running }
        let importer = PlaylistImporter(store: store, credentials: credentials, http: http)
        // Uppgiften ärver huvudaktören och kan inte starta förrän `importTasks[id]` är satt nedan.
        let task = Task { [weak self] in
            do {
                for try await phase in importer.run(playlistID: id) {
                    self?.importState[id] = phase
                }
            } catch is CancellationError {
                self?.importState[id] = nil
            } catch {
                self?.importState[id] = nil
                self?.report(error)
            }
            self?.importTasks[id] = nil
            await self?.reloadPlaylists()
        }
        importTasks[id] = task
        return task
    }

    func refreshAll() async {
        let tasks = playlists.map { startRefresh($0.id) }
        for t in tasks { await t.value }
    }

    /// Avbryter pågående import och tar bort Keychain-posten, metadata och alla databasrader. Allt försöks
    /// även om något steg misslyckas.
    func remove(_ id: UUID) async {
        if let running = importTasks[id] {
            running.cancel()
            await running.value
        }
        let store = store, credentials = credentials
        var failure: Error?
        do {
            try await offMain(honorsCancellation: false) { try credentials.delete(for: id) }
        } catch {
            failure = error
        }
        do {
            try await offMain(honorsCancellation: false) { try store.deletePlaylist(id) }
        } catch {
            failure = failure ?? ImportError.storageFailed
        }
        metadata.remove([id])
        importState[id] = nil
        counts[id] = nil
        if let failure { report(failure) }
        await reloadPlaylists()
    }

    /// Lägger tillbaka metadata-spellistor som saknas i databasen. Returnerar de återställda id:na.
    private func restoreMissingPlaylists() async -> [UUID] {
        let entries = metadata.all()
        guard !entries.isEmpty else { return [] }
        let store = store, credentials = credentials
        do {
            let (restored, orphaned) = try await offMain { () throws -> ([UUID], [UUID]) in
                let existing = Set(try store.playlists().map(\.id))
                var restored: [UUID] = [], orphaned: [UUID] = []
                for entry in entries where !existing.contains(entry.id) {
                    let secret: PlaylistSecret?
                    // Läsfel (t.ex. låst Keychain): behåll posten och försök vid nästa start.
                    do { secret = try credentials.load(for: entry.id) } catch { continue }
                    guard secret != nil else {
                        orphaned.append(entry.id)
                        continue
                    }
                    try store.upsertPlaylist(entry.playlist)
                    restored.append(entry.id)
                }
                return (restored, orphaned)
            }
            metadata.remove(orphaned)
            return restored
        } catch {
            report(ImportError.storageFailed)
            return []
        }
    }

    private func reloadPlaylists() async {
        let store = store
        do {
            let (lists, counts) = try await offMain(honorsCancellation: false) {
                let lists = try store.playlists()
                var counts: [UUID: [ContentKind: Int]] = [:]
                for p in lists { counts[p.id] = try store.counts(playlistID: p.id) }
                return (lists, counts)
            }
            playlists = lists
            self.counts = counts
        } catch {
            report(ImportError.storageFailed)
        }
    }

    private func report(_ error: Error) {
        lastError = UserFacingError.message(for: error)
    }
}
