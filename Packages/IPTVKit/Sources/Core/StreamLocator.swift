import Foundation

/// Lagrar aldrig credentials: `.template` innehåller platshållarna `{server}`, `{username}` och `{password}`.
public enum StreamLocator: Sendable, Codable, Hashable {
    case xtream(kind: ContentKind, streamID: String, container: String)
    case template(String)
}

extension StreamLocator {
    public func resolve(with secret: PlaylistSecret) throws -> URL {
        let (server, username, password) = try Self.parts(of: secret, credentialsRequired: isXtream)
        switch self {
        case let .xtream(kind, streamID, container):
            guard let username, let password else { throw CoreError.secretKindMismatch }
            let s = "\(server)/\(kind.rawValue)/\(Self.encode(username))/\(Self.encode(password))/\(streamID).\(container)"
            return try Self.url(s)
        case let .template(template):
            if template.contains("{username}") && username == nil { throw CoreError.missingCredentials }
            if template.contains("{password}") && password == nil { throw CoreError.missingCredentials }
            let s = template
                .replacingOccurrences(of: "{server}", with: server)
                .replacingOccurrences(of: "{username}", with: Self.encode(username ?? ""))
                .replacingOccurrences(of: "{password}", with: Self.encode(password ?? ""))
            return try Self.url(s)
        }
    }

    private var isXtream: Bool {
        if case .xtream = self { return true }
        return false
    }

    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func url(_ s: String) throws -> URL {
        guard let url = URL(string: s) else { throw CoreError.invalidURL }
        return url
    }

    /// Returnerar server (utan avslutande snedstreck) samt ev. username/password.
    /// För `.m3u` hämtas de ur URL:ens query; saknas de och `credentialsRequired` är satt blir det `secretKindMismatch`.
    private static func parts(of secret: PlaylistSecret, credentialsRequired: Bool) throws -> (String, String?, String?) {
        switch secret {
        case let .xtream(server, username, password):
            var s = server.absoluteString
            while s.hasSuffix("/") { s.removeLast() }
            return (s, username, password)
        case let .m3u(url, _):
            guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = c.scheme, let host = c.host else {
                throw CoreError.invalidURL
            }
            var server = "\(scheme)://\(host)"
            if let port = c.port { server += ":\(port)" }
            let items = c.queryItems ?? []
            let u = items.first { $0.name == "username" }?.value
            let p = items.first { $0.name == "password" }?.value
            if credentialsRequired && (u == nil || p == nil) { throw CoreError.secretKindMismatch }
            return (server, u, p)
        }
    }
}
