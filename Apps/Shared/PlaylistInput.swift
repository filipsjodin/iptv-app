import Core
import Foundation

/// Formulärdata för en ny spellista. Ren logik (ingen UI) så att valideringen kan testas.
struct PlaylistInput: Equatable {
    enum Kind: String, CaseIterable, Identifiable, Hashable {
        case xtream, m3u
        var id: String { rawValue }
    }

    var kind: Kind = .xtream
    var name = ""
    var server = ""
    var username = ""
    var password = ""
    var m3uURL = ""
    var epgURL = ""

    /// Trimmar, lägger till `http://` om schema saknas och kräver http/https samt en icke-tom värd.
    static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }

    var trimmedName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        return switch kind {
        case .xtream: String(localized: "Xtream playlist")
        case .m3u: String(localized: "M3U playlist")
        }
    }

    /// Xtream-serverfältet tolkat: query och fragment tas bort. Slutar sökvägen på `get.php`, `player_api.php`
    /// eller `xmltv.php` blir servern scheme://host[:port] plus ev. path-prefix före php-filen, och
    /// `username`/`password` ur queryn returneras (används bara om motsvarande fält är tomma).
    static func parseXtreamServer(_ raw: String) -> (server: URL, username: String?, password: String?)? {
        guard let url = normalizedURL(raw),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = c.queryItems ?? []
        c.query = nil
        c.fragment = nil
        var segments = c.path.split(separator: "/").map(String.init)
        var user: String?
        var pass: String?
        if let last = segments.last, xtreamEndpoints.contains(last.lowercased()) {
            segments.removeLast()
            user = items.first { $0.name == "username" }?.value.flatMap { $0.isEmpty ? nil : $0 }
            pass = items.first { $0.name == "password" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        c.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard let server = c.url else { return nil }
        return (server, user, pass)
    }

    private static let xtreamEndpoints: Set<String> = ["get.php", "player_api.php", "xmltv.php"]

    /// Fyller tomma användarnamn/lösenord ur en inklistrad Xtream-URL och skriver om servern till bara serveradressen.
    /// Gör ingenting om URL:en inte innehåller några inloggningsuppgifter.
    mutating func absorbCredentialsFromServer() {
        guard let parsed = Self.parseXtreamServer(server), parsed.username != nil || parsed.password != nil else { return }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let u = parsed.username { username = u }
        if password.isEmpty, let p = parsed.password { password = p }
        server = parsed.server.absoluteString
    }

    /// `nil` när formuläret inte är giltigt. Lösenordet trimmas aldrig (mellanslag kan vara en del av det).
    var secret: PlaylistSecret? {
        switch kind {
        case .xtream:
            guard let parsed = Self.parseXtreamServer(server) else { return nil }
            let typed = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let user = typed.isEmpty ? (parsed.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : typed
            let pass = password.isEmpty ? (parsed.password ?? "") : password
            guard !user.isEmpty, !pass.isEmpty else { return nil }
            return .xtream(server: parsed.server, username: user, password: pass)
        case .m3u:
            guard let url = Self.normalizedURL(m3uURL) else { return nil }
            let epgRaw = epgURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if epgRaw.isEmpty { return .m3u(url: url, epgURL: nil) }
            guard let epg = Self.normalizedURL(epgRaw) else { return nil }
            return .m3u(url: url, epgURL: epg)
        }
    }

    var isValid: Bool { secret != nil }
}
