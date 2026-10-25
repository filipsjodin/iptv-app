import Foundation

public enum CoreError: Error, Sendable, Hashable {
    case missingSecret
    case secretKindMismatch
    case invalidURL
    case missingCredentials
}

/// Hemlig del av en spellista (server, inloggning, URL). Lagras endast i `CredentialStore`.
public enum PlaylistSecret: Sendable, Codable, Hashable {
    case xtream(server: URL, username: String, password: String)
    case m3u(url: URL, epgURL: URL?)
}

// Hemligheten får aldrig synas i print, dump, interpolation eller testutdata.
extension PlaylistSecret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .xtream: "PlaylistSecret.xtream(<redacted>)"
        case .m3u: "PlaylistSecret.m3u(<redacted>)"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}
