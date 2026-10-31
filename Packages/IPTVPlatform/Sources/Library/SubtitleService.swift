import Foundation
import Subtitles
#if canImport(os)
import os
#endif

/// Knyter ihop OpenSubtitles-klienten, den lokala lagringen och de sparade uppgifterna. Uppgifterna (användarnamn
/// och lösenord) finns bara i `credentials` (Keychain) och skickas bara till klientens inloggning; inga fel eller
/// beskrivningar härifrån innehåller dem.
public final class SubtitleService: Sendable {
    private let client: OpenSubtitlesClient
    private let store: SubtitleStore
    private let credentials: any OpenSubtitlesCredentialStore

    public init(client: OpenSubtitlesClient, store: SubtitleStore, credentials: any OpenSubtitlesCredentialStore) {
        self.client = client
        self.store = store
        self.credentials = credentials
    }

    /// Sorterad: förvalda språk först (i given ordning), därefter betyg, därefter antal nedladdningar.
    public func search(_ query: OpenSubtitlesQuery, preferredLanguages: [String]) async throws -> [OpenSubtitlesResult] {
        #if canImport(os)
        // Bara intervallets namn; varken sökfrågan, titeln eller uppgifter loggas.
        let signposter = OSSignposter(subsystem: "se.sjodin.iptv", category: "subtitles")
        let interval = signposter.beginInterval("subtitleSearch")
        defer { signposter.endInterval("subtitleSearch", interval) }
        #endif
        let results = try await client.search(query)
        return OpenSubtitlesResult.sorted(results, preferredLanguages: preferredLanguages)
    }

    /// Hämtar och lagrar undertexten. Loggar in med sparade uppgifter om klienten saknar giltig session (också om
    /// servern avvisar en utgången token); utan sparade uppgifter kastas `OpenSubtitlesError.notLoggedIn`.
    public func download(_ result: OpenSubtitlesResult, for key: SubtitleKey) async throws
        -> (StoredSubtitle, OpenSubtitlesQuota)
    {
        try await ensureLoggedIn()
        let downloaded: (data: Data, quota: OpenSubtitlesQuota)
        do {
            downloaded = try await client.download(fileID: result.id)
        } catch OpenSubtitlesError.notLoggedIn {
            // Klienten har rensat den utgångna token; ett nytt försök med sparade uppgifter.
            try await ensureLoggedIn()
            downloaded = try await client.download(fileID: result.id)
        }
        let stored = try store.save(downloaded.data, result: result, for: key)
        return (stored, downloaded.quota)
    }

    /// Sparar uppgifterna i Keychain först när inloggningen lyckats.
    public func login(username: String, password: String) async throws -> OpenSubtitlesQuota {
        let quota = try await client.login(username: username, password: password)
        try credentials.save(OpenSubtitlesCredentials(username: username, password: password))
        return quota
    }

    /// Glömmer sessionen och raderar de sparade uppgifterna.
    public func logout() throws {
        client.logout()
        try credentials.clear()
    }

    public func quota() async throws -> OpenSubtitlesQuota {
        try await ensureLoggedIn()
        do {
            return try await client.quota()
        } catch OpenSubtitlesError.notLoggedIn {
            try await ensureLoggedIn()
            return try await client.quota()
        }
    }

    private func ensureLoggedIn() async throws {
        if client.isLoggedIn { return }
        guard let saved = try credentials.load() else { throw OpenSubtitlesError.notLoggedIn }
        _ = try await client.login(username: saved.username, password: saved.password)
    }
}
