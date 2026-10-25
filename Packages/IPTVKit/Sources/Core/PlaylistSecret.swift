import Foundation

public enum CoreError: Error, Sendable, Hashable {
    case missingSecret
    case secretKindMismatch
    case invalidURL
}

/// Hemlig del av en spellista (server, inloggning, URL). Lagras endast i `CredentialStore`.
public enum PlaylistSecret: Sendable, Codable, Hashable {
    case xtream(server: URL, username: String, password: String)
    case m3u(url: URL, epgURL: URL?)
}
