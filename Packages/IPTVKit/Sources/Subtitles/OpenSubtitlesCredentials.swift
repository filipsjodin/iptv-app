import Foundation
import PlaybackCore

/// Användarnamn och lösenord för OpenSubtitles. Lagras bara i Keychain. Skriver aldrig ut innehållet:
/// varken `description`, `debugDescription` eller reflektion (`dump`, `print`) avslöjar något.
public struct OpenSubtitlesCredentials: Sendable, Equatable, Codable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String { "OpenSubtitlesCredentials(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Lagring av OpenSubtitles-uppgifter (Keychain i appen, minne i tester).
public protocol OpenSubtitlesCredentialStore: Sendable {
    func load() throws -> OpenSubtitlesCredentials?
    func save(_ credentials: OpenSubtitlesCredentials) throws
    func clear() throws
}

/// För tester och previews.
// @unchecked Sendable: all åtkomst till `stored` sker under `lock`.
public final class InMemoryOpenSubtitlesCredentialStore: OpenSubtitlesCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: OpenSubtitlesCredentials?

    public init(_ initial: OpenSubtitlesCredentials? = nil) { stored = initial }

    public func load() throws -> OpenSubtitlesCredentials? { lock.withLock { stored } }
    public func save(_ credentials: OpenSubtitlesCredentials) throws { lock.withLock { stored = credentials } }
    public func clear() throws { lock.withLock { stored = nil } }
}

extension OpenSubtitlesResult {
    /// Förvalda språk först (i given ordning), därefter högst betyg, därefter flest nedladdningar. Stabil: lika
    /// poster ordnas på `id` så att resultatet är deterministiskt.
    public static func sorted(_ results: [OpenSubtitlesResult], preferredLanguages: [String]) -> [OpenSubtitlesResult] {
        var rank: [String: Int] = [:]
        for (i, raw) in preferredLanguages.enumerated() {
            let code = LanguageCode.normalize(raw) ?? raw.lowercased()
            if rank[code] == nil { rank[code] = i }
        }
        func r(_ x: OpenSubtitlesResult) -> Int { rank[x.language] ?? Int.max }
        return results.sorted { a, b in
            if r(a) != r(b) { return r(a) < r(b) }
            if a.rating != b.rating { return a.rating > b.rating }
            if a.downloadCount != b.downloadCount { return a.downloadCount > b.downloadCount }
            return a.id < b.id
        }
    }
}
