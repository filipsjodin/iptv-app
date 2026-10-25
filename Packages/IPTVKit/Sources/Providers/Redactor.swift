import Foundation
import Core

/// Ersätter inloggning, host och port ur en `PlaylistSecret` i fri text (sökvägar, query, felmeddelanden).
public enum Redactor {
    public static let placeholder = "REDACTED"

    private struct Needle {
        let bytes: [UInt8]
        let ignoreCase: Bool
        let isHost: Bool
    }

    public static func redact(_ text: String, secret: PlaylistSecret) -> String {
        let (values, hosts, ports) = sensitive(in: secret)
        var needles: [Needle] = []
        var seen = Set<[UInt8]>()
        func add(_ s: String, ignoreCase: Bool, isHost: Bool) {
            guard !s.isEmpty else { return }
            let b = Array((ignoreCase ? s.lowercased() : s).utf8)
            if seen.insert(b + [ignoreCase ? 1 : 0]).inserted {
                needles.append(Needle(bytes: b, ignoreCase: ignoreCase, isHost: isHost))
            }
        }
        for v in values { for variant in variants(of: v) { add(variant, ignoreCase: false, isHost: false) } }
        for h in hosts {
            add(h, ignoreCase: true, isHost: true)
            add(h.addingPercentEncoding(withAllowedCharacters: unreserved) ?? h, ignoreCase: true, isHost: true)
            if h.contains(":") { add("[" + h + "]", ignoreCase: true, isHost: true) }   // IPv6 med hakparenteser
        }
        // Längst först så att den längsta träffen vinner vid samma startposition.
        needles.sort { $0.bytes.count > $1.bytes.count }
        let portBytes = ports.map { Array(":\($0)".utf8) }

        let src = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(src.count)
        let mark = Array(placeholder.utf8)
        var i = 0
        while i < src.count {
            guard let n = needles.first(where: { i + $0.bytes.count <= src.count && matches($0, src, i) }) else {
                out.append(src[i])
                i += 1
                continue
            }
            out += mark
            i += n.bytes.count
            if n.isHost, let p = portBytes.first(where: { i + $0.count <= src.count && Array(src[i..<(i + $0.count)]) == $0 }) {
                i += p.count
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func matches(_ n: Needle, _ src: [UInt8], _ at: Int) -> Bool {
        for (k, b) in n.bytes.enumerated() {
            var c = src[at + k]
            if n.ignoreCase, c >= 65, c <= 90 { c += 32 }
            if c != b { return false }
        }
        return true
    }

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// Rå, procentkodade (strikt och URL-vänlig, versaler och gemener) samt `+`-kodade varianter.
    private static func variants(of value: String) -> [String] {
        var result: [String] = [value]
        let strict = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
        let loose = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        let pathy = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
        for e in [strict, loose, pathy] {
            result.append(e)
            result.append(lowerHex(e))
        }
        result.append(value.replacingOccurrences(of: " ", with: "+"))
        result.append(strict.replacingOccurrences(of: "%20", with: "+"))
        return result
    }

    private static func lowerHex(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 2 < chars.count {
                out.append("%")
                out.append(contentsOf: String(chars[i + 1...i + 2]).lowercased())
                i += 3
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    private static let staticWords: Set<String> = [
        "get.php", "player_api.php", "xmltv.php", "playlist.m3u", "playlist.m3u8", "get", "api", "m3u", "m3u8",
        "m3u_plus", "playlist", "ts", "hls", "live", "movie", "series", "xmltv", "php",
    ]

    /// Kända icke-hemliga ord, `*.m3u`/`*.m3u8`/`*.php`-filnamn samt värden kortare än 3 tecken (skulle förstöra text).
    private static func isStaticWord(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.count < 3 || staticWords.contains(l) || l.hasSuffix(".m3u8") || l.hasSuffix(".m3u")
    }

    private static func sensitive(in secret: PlaylistSecret) -> (values: [String], hosts: [String], ports: [Int]) {
        var values: [String] = []
        var hosts: [String] = []
        var ports: [Int] = []
        func addURL(_ url: URL) {
            guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            if var h = c.host {
                // Vissa plattformar returnerar IPv6-värdar med hakparenteser; normalisera till utan.
                if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
                hosts.append(h)
            }
            if let p = c.port { ports.append(p) }
        }
        switch secret {
        case let .xtream(server, username, password):
            addURL(server)
            values += [username, password]
        case let .m3u(url, epg):
            addURL(url)
            if let epg { addURL(epg) }
            // M3U-URL:er har ingen känd struktur: alla query-värden och path-segment är hemliga utom välkända
            // statiska ord och filnamn.
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            for item in comps?.queryItems ?? [] {
                guard let v = item.value, !v.isEmpty else { continue }
                if item.name == "username" || item.name == "password" || !isStaticWord(v) { values.append(v) }
            }
            for seg in (comps?.path ?? "").split(separator: "/") where !isStaticWord(String(seg)) {
                values.append(String(seg).removingPercentEncoding ?? String(seg))
            }
        }
        return (values, hosts, ports)
    }
}
