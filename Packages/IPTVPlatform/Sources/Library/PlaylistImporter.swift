import Core
import Foundation
import Providers
import os

public enum ImportPhase: Sendable, Equatable {
    case connecting, downloading, parsing, saving
    case done(counts: [ContentKind: Int])
}

public enum ImportError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownPlaylist
    case secretUnreadable
    case storageFailed
    public var description: String {
        switch self {
        case .unknownPlaylist: "Spellistan finns inte"
        case .secretUnreadable: "Inloggningsuppgifterna kunde inte läsas"
        case .storageFailed: "Katalogen kunde inte sparas"
        }
    }
}

public struct PlaylistImporter: Sendable {
    private let store: LibraryStore
    private let credentials: CredentialStore
    private let http: HTTPClient

    public init(store: LibraryStore, credentials: CredentialStore, http: HTTPClient) {
        self.store = store
        self.credentials = credentials
        self.http = http
    }

    public func run(playlistID: UUID) -> AsyncThrowingStream<ImportPhase, Error> {
        let store = store, credentials = credentials, http = http
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    continuation.yield(.connecting)
                    let loaded: PlaylistSecret?
                    do { loaded = try credentials.load(for: playlistID) } catch let e as CoreError { throw e } catch {
                        throw Self.local(error, as: .secretUnreadable)
                    }
                    guard let secret = loaded else { throw CoreError.missingSecret }
                    let exists: Bool
                    do { exists = try store.playlists().contains(where: { $0.id == playlistID }) } catch {
                        throw Self.local(error, as: .storageFailed)
                    }
                    guard exists else { throw ImportError.unknownPlaylist }
                    try Task.checkCancellation()
                    continuation.yield(.downloading)
                    let catalog: ProviderCatalog
                    switch secret {
                    case let .xtream(server, username, password):
                        let client = XtreamClient(server: server, username: username, password: password, http: http)
                        catalog = try await client.catalog()
                        continuation.yield(.parsing)
                    case let .m3u(url, _):
                        let text = try await Self.download(url, http: http)
                        try Task.checkCancellation()
                        continuation.yield(.parsing)
                        // HTML-sidor, tomma svar och "expired"-texter får aldrig ersätta katalogen.
                        guard text.range(of: "#EXTINF", options: .caseInsensitive) != nil else { throw ProviderError.invalidResponse }
                        let parsed = M3UParser.parse(text)
                        guard !parsed.entries.isEmpty else { throw ProviderError.invalidResponse }
                        catalog = M3UMapper.catalog(from: parsed, secret: secret)
                    }
                    try Task.checkCancellation()
                    // Skyddsnät: en helt tom katalog får inte radera ett befintligt bibliotek.
                    if catalog.movies.isEmpty && catalog.series.isEmpty && catalog.live.isEmpty {
                        let stored: Int
                        do { stored = try store.counts(playlistID: playlistID).values.reduce(0, +) } catch {
                            throw Self.local(error, as: .storageFailed)
                        }
                        if stored > 0 { throw ProviderError.invalidResponse }
                    }
                    continuation.yield(.saving)
                    let counts: [ContentKind: Int]
                    do {
                        try store.replaceCatalog(catalog, playlistID: playlistID, now: Date())
                        counts = try store.counts(playlistID: playlistID)
                    } catch {
                        throw Self.local(error, as: .storageFailed)
                    }
                    continuation.yield(.done(counts: counts))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.sanitize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func download(_ url: URL, http: HTTPClient) async throws -> String {
        let data: Data
        let code: Int
        do {
            (data, code) = try await http.get(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ProviderError.unreachable  // URLError kan bära URL:en med inloggning
        }
        guard (200..<300).contains(code) else {
            throw (code == 401 || code == 403) ? ProviderError.unauthorized : ProviderError.http(code)
        }
        // En eventuell UTF-8-BOM följer med in i strängen; M3UParser hoppar över den.
        if let s = String(data: data, encoding: .utf8) { return s }
        // Fallback: ogiltig UTF-8 tolkas som Latin-1 (tappar inga byte, men kan ge fel tecken
        // om källan egentligen använder en annan teckentabell).
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Lokala fel (Keychain, databas) får inte skyllas på leverantören. Detaljer loggas bara i DEBUG, privat.
    private static func local(_ error: Error, as mapped: ImportError) -> ImportError {
        #if DEBUG
        Logger(subsystem: "se.sjodin.iptv", category: "import")
            .error("\(mapped.description, privacy: .public): \(String(describing: error), privacy: .private)")
        #endif
        return mapped
    }

    /// Släpper bara igenom fel med fasta beskrivningar; allt annat blir `.invalidResponse`.
    private static func sanitize(_ error: Error) -> Error {
        switch error {
        case is ProviderError, is CoreError, is ImportError, is CancellationError: error
        default: ProviderError.invalidResponse
        }
    }
}
