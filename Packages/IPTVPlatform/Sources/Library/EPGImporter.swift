import Core
import Foundation
import Providers

/// Hämtar och sparar tablån (XMLTV) för en spellista. Tvåpassmetod med strömmande tolkning och mellanlagring:
/// pass 1 läser bara `<channel>` för matchningen, pass 2 mellanlagrar program för matchade kanaler, och först när
/// allt gått bra ersätts den gamla tablån i en enda transaktion.
public struct EPGImporter: Sendable {
    public static let refreshInterval: TimeInterval = 12 * 3600
    static let batchSize = 5_000
    private static let inFlight = InFlight()

    /// Pågående importer per (databas, spellista). Trådsäker.
    private final class InFlight: @unchecked Sendable {
        struct Key: Hashable { let store: ObjectIdentifier; let playlistID: UUID }
        private let lock = NSLock()
        private var active: Set<Key> = []
        func acquire(_ key: Key) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return active.insert(key).inserted
        }
        func release(_ key: Key) {
            lock.lock(); active.remove(key); lock.unlock()
        }
    }

    private let store: LibraryStore
    private let epg: EPGStore
    private let credentials: CredentialStore
    private let http: HTTPClient
    private let clock: @Sendable () -> Date

    public init(store: LibraryStore, epg: EPGStore, credentials: CredentialStore, http: HTTPClient,
                clock: @Sendable @escaping () -> Date = Date.init) {
        self.store = store
        self.epg = epg
        self.credentials = credentials
        self.http = http
        self.clock = clock
    }

    /// Billig och synkron: sant om tablån aldrig hämtats, är äldre än `refreshInterval` eller inte kan läsas.
    public func needsRefresh(playlistID: UUID) -> Bool {
        guard let last = try? epg.lastFetch(playlistID: playlistID) else { return true }
        return clock().timeIntervalSince(last) >= Self.refreshInterval
    }

    /// Hämtar, tolkar med fönstret (−1 d … +7 d från `clock()`) och bara matchade kanaler, sparar atomärt.
    /// Returnerar antal program. Misslyckande lämnar gammal tablå orörd. Fel innehåller aldrig URL eller inloggning.
    public func refresh(playlistID: UUID) async throws -> Int {
        // Mellanlagringen är nyckad på spellista: två samtidiga körningar skulle riva upp varandra.
        let key = InFlight.Key(store: ObjectIdentifier(epg), playlistID: playlistID)
        guard Self.inFlight.acquire(key) else { return 0 }
        defer { Self.inFlight.release(key) }
        let task = Task.detached(priority: .utility) { try await self.run(playlistID: playlistID) }
        return try await withTaskCancellationHandler {
            do { return try await task.value } catch { throw Self.sanitize(error) }
        } onCancel: { task.cancel() }
    }

    private func run(playlistID: UUID) async throws -> Int {
        let loaded: PlaylistSecret?
        do { loaded = try credentials.load(for: playlistID) } catch { throw ImportError.secretUnreadable }
        guard let secret = loaded else { throw CoreError.missingSecret }
        guard let url = EPGSource.url(for: secret) else { return 0 }

        let now = clock()
        let window = now.addingTimeInterval(-86_400)...now.addingTimeInterval(7 * 86_400)

        let downloaded = try await Self.fetch(url, http: http)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try Task.checkCancellation()
        let xml: URL
        do { xml = try GzipFile.inflate(downloaded) } catch { throw ProviderError.invalidResponse }
        defer { if xml != downloaded { try? FileManager.default.removeItem(at: xml) } }
        try Task.checkCancellation()

        // Pass 1: bara kanalerna (programmen ligger utanför ett tomt fönster och släpps direkt).
        var channels: [EPGChannel] = []
        let past = Date.distantPast
        do {
            try XMLTVParser(window: past...past, wantedChannelIDs: nil)
                .parse(contentsOf: xml, onChannel: { channels.append($0) }, onProgram: { _ in })
        } catch { throw ProviderError.invalidResponse }
        try Task.checkCancellation()

        let matched: [String: String]
        do {
            let splits = try epg.splitProviderIDs(playlistID: playlistID)
            let groups = try store.channelGroups(playlistID: playlistID, splitProviderIDs: splits)
            matched = EPGMatcher.match(groups: groups, xmltvChannels: channels)
        } catch { throw ImportError.storageFailed }
        let wanted = Set(matched.values)
        channels = []
        guard !wanted.isEmpty else { return 0 }

        // Pass 2: program för matchade kanaler, i batchar till mellanlagringen.
        do { try epg.beginStaging(playlistID: playlistID) } catch { throw ImportError.storageFailed }
        var staged = 0
        var failure: Error?
        var cancelled = false
        var batch: [EPGProgram] = []
        func flush() {
            guard failure == nil, !batch.isEmpty else { batch = []; return }
            do {
                try epg.stage(playlistID: playlistID, programs: batch)
                staged += batch.count
            } catch { failure = ImportError.storageFailed }
            batch = []
        }
        do {
            try XMLTVParser(window: window, wantedChannelIDs: wanted).parse(contentsOf: xml, onChannel: { _ in }, onProgram: { p in
                // Ogiltiga program (slut <= start) skulle få tabellens CHECK att avbryta hela importen.
                // onProgram kan inte kasta: vid avbrott slutar vi lagra och avbryter efter tolkningen.
                if !cancelled, Task.isCancelled { cancelled = true }
                guard failure == nil, !cancelled, p.end > p.start else { return }
                batch.append(p)
                if batch.count >= Self.batchSize { flush() }
            })
            flush()
            if let failure { throw failure }
            if cancelled { throw CancellationError() }
            try Task.checkCancellation()
            guard staged > 0 else {
                try? epg.discardStaging(playlistID: playlistID)
                return 0
            }
            do { try epg.commitStaging(playlistID: playlistID, fetchedAt: now) } catch { throw ImportError.storageFailed }
            return staged
        } catch {
            try? epg.discardStaging(playlistID: playlistID)
            throw error
        }
    }

    /// Hämtar till temporärfil. Alla fel mappas till fasta felvärden; URLError kan bära URL:en med inloggning.
    private static func fetch(_ url: URL, http: HTTPClient) async throws -> URL {
        let file: URL
        let status: Int
        do {
            (file, status) = try await http.download(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let e = error as? ProviderError { throw e }
            throw ProviderError.unreachable
        }
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: file)
            throw (status == 401 || status == 403) ? ProviderError.unauthorized : ProviderError.http(status)
        }
        return file
    }

    /// Släpper bara igenom fel med fasta beskrivningar; allt annat blir `.invalidResponse`.
    private static func sanitize(_ error: Error) -> Error {
        switch error {
        case is ProviderError, is CoreError, is ImportError, is CancellationError: error
        default: ProviderError.invalidResponse
        }
    }
}
