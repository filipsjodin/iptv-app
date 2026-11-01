import Foundation
import Core

/// Id-baserade, filsystemssäkra relativa sökvägar. Aldrig titlar.
public enum DownloadPaths {
    private static let knownContainers: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "webm", "mpg", "mpeg", "wmv", "flv"]

    /// `<profil>/<spellista>/<movie|series|live>/<sanerat-id>-<hash>` (alltid fyra segment, högst ~120 byte).
    /// Det saniterade id-prefixet är bara läsbarhet; unikheten kommer från en 128-bitars hash av hela id:t.
    public static func relativeDirectory(for key: DownloadKey) -> String {
        let prefix = sanitized(key.providerID, limit: 24)
        let name = "\(prefix)-\(hash128(key.providerID))"
        return "\(key.profileID.uuidString)/\(key.playlistID.uuidString)/\(key.kind.rawValue)/\(name)"
    }

    /// Okänd eller saknad container: `nil`/tom ger `mp4` (vanligaste), okänt eller osäkert värde ger `bin`.
    public static func fileName(container: String?) -> String {
        guard let container, !container.isEmpty else { return "media.mp4" }
        let ext = container.lowercased()
        return knownContainers.contains(ext) ? "media.\(ext)" : "media.bin"
    }

    private static func sanitized(_ s: String, limit: Int) -> String {
        var out = ""
        for u in s.unicodeScalars {
            let v = u.value
            let ok = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 45
            out.unicodeScalars.append(ok ? u : "_")
            if out.count >= limit { break }
        }
        return out.isEmpty ? "id" : out
    }

    /// Deterministisk (till skillnad från `Hasher`): två FNV-1a-64 med olika startvärden, hex.
    private static func hash128(_ s: String) -> String {
        var a: UInt64 = 0xcbf29ce484222325
        var b: UInt64 = 0x84222325cbf29ce4
        let prime: UInt64 = 0x100000001b3
        for byte in s.utf8 {
            a = (a ^ UInt64(byte)) &* prime
            b = ((b &* prime) ^ UInt64(byte)) &+ 0x9e3779b97f4a7c15
        }
        return hex(a) + hex(b)
    }

    private static func hex(_ v: UInt64) -> String {
        let h = String(v, radix: 16)
        return String(repeating: "0", count: 16 - h.count) + h
    }
}
