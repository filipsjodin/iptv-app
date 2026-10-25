import Core
import Foundation
import Providers

public enum ImportPhase: Sendable, Equatable {
    case connecting, downloading, parsing, saving
    case done(counts: [ContentKind: Int])
}

public enum ImportError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownPlaylist
    public var description: String { "Spellistan finns inte" }
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
                    guard let secret = try credentials.load(for: playlistID) else { throw CoreError.missingSecret }
                    guard try store.playlists().contains(where: { $0.id == playlistID }) else {
                        throw ImportError.unknownPlaylist
                    }
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
                        catalog = M3UMapper.catalog(from: M3UParser.parse(text), secret: secret)
                    }
                    try Task.checkCancellation()
                    continuation.yield(.saving)
                    try store.replaceCatalog(catalog, playlistID: playlistID, now: Date())
                    continuation.yield(.done(counts: try store.counts(playlistID: playlistID)))
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
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Släpper bara igenom fel med fasta beskrivningar; allt annat blir `.invalidResponse`.
    private static func sanitize(_ error: Error) -> Error {
        switch error {
        case is ProviderError, is CoreError, is ImportError, is CancellationError: error
        default: ProviderError.invalidResponse
        }
    }
}
