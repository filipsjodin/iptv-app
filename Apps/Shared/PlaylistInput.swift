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

    /// `nil` när formuläret inte är giltigt.
    var secret: PlaylistSecret? {
        switch kind {
        case .xtream:
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = Self.normalizedURL(server), !user.isEmpty, !pass.isEmpty else { return nil }
            return .xtream(server: url, username: user, password: pass)
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
