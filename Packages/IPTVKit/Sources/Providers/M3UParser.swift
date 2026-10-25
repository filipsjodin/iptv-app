import Foundation

public struct M3UEntry: Sendable, Hashable {
    public var title: String
    public var duration: Int
    public var attributes: [String: String]
    public var url: String

    public init(title: String, duration: Int, attributes: [String: String], url: String) {
        self.title = title
        self.duration = duration
        self.attributes = attributes
        self.url = url
    }
}

public struct M3UPlaylist: Sendable, Hashable {
    public var headerAttributes: [String: String]
    public var entries: [M3UEntry]

    public init(headerAttributes: [String: String] = [:], entries: [M3UEntry] = []) {
        self.headerAttributes = headerAttributes
        self.entries = entries
    }
}

/// Tolerant M3U/M3U8-tolk. Arbetar på UTF-8-bytes i ett enda pass (linjärt) utan regex.
public enum M3UParser {
    private static let lf = UInt8(ascii: "\n")
    private static let cr = UInt8(ascii: "\r")
    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
    private static let quote = UInt8(ascii: "\"")
    private static let comma = UInt8(ascii: ",")
    private static let equals = UInt8(ascii: "=")
    private static let hash = UInt8(ascii: "#")

    private static let extm3u = Array("#EXTM3U".utf8)
    private static let extinf = Array("#EXTINF:".utf8)
    private static let extgrp = Array("#EXTGRP:".utf8)

    public static func parse(_ text: String) -> M3UPlaylist {
        let bytes = Array(text.utf8)
        var header: [String: String] = [:]
        var entries: [M3UEntry] = []
        var pending: M3UEntry?

        var i = 0
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        let n = bytes.count

        while i < n {
            var end = i
            while end < n && bytes[end] != lf { end += 1 }
            var lo = i
            var hi = end
            i = end + 1
            while lo < hi && isBlank(bytes[lo]) { lo += 1 }
            while hi > lo && (isBlank(bytes[hi - 1]) || bytes[hi - 1] == cr) { hi -= 1 }
            if lo >= hi { continue }

            if bytes[lo] == hash {
                if hasPrefix(bytes, lo, hi, extinf) {
                    pending = parseExtInf(bytes, lo + extinf.count, hi)
                } else if hasPrefix(bytes, lo, hi, extm3u) {
                    var p = lo + extm3u.count
                    header = scanAttributes(bytes, &p, hi)
                } else if hasPrefix(bytes, lo, hi, extgrp), pending != nil, pending?.attributes["group-title"] == nil {
                    let g = string(bytes, lo + extgrp.count, hi).trimmingCharacters(in: .whitespaces)
                    if !g.isEmpty { pending?.attributes["group-title"] = g }
                }
                continue
            }

            if var entry = pending {
                entry.url = string(bytes, lo, hi)
                entries.append(entry)
                pending = nil
            }
        }
        return M3UPlaylist(headerAttributes: header, entries: entries)
    }

    // MARK: - Hjälpare

    private static func isBlank(_ b: UInt8) -> Bool { b == space || b == tab }

    private static func string(_ bytes: [UInt8], _ lo: Int, _ hi: Int) -> String {
        String(decoding: bytes[lo..<hi], as: UTF8.self)
    }

    private static func hasPrefix(_ bytes: [UInt8], _ lo: Int, _ hi: Int, _ prefix: [UInt8]) -> Bool {
        guard hi - lo >= prefix.count else { return false }
        for k in 0..<prefix.count where bytes[lo + k] != prefix[k] { return false }
        return true
    }

    /// `start` pekar direkt efter `#EXTINF:`.
    private static func parseExtInf(_ bytes: [UInt8], _ start: Int, _ hi: Int) -> M3UEntry {
        var p = start
        while p < hi && isBlank(bytes[p]) { p += 1 }
        let durStart = p
        while p < hi && !isBlank(bytes[p]) && bytes[p] != comma { p += 1 }
        let durToken = string(bytes, durStart, p)
        let duration: Int
        if let d = Int(durToken) {
            duration = d
        } else if let d = Double(durToken), d.isFinite, abs(d) < 1e12 {
            duration = Int(d)
        } else {
            duration = -1
        }

        let attributes = scanAttributes(bytes, &p, hi)
        var title = ""
        if p < hi && bytes[p] == comma {
            title = string(bytes, p + 1, hi).trimmingCharacters(in: .whitespaces)
        }
        if title.isEmpty, let name = attributes["tvg-name"] { title = name }
        return M3UEntry(title: title, duration: duration, attributes: attributes, url: "")
    }

    /// Läser `key="value"`-par (eller `key=value`) tills första kommatecknet utanför citattecken, eller radslut.
    /// Lämnar `p` på kommatecknet (eller `hi`).
    private static func scanAttributes(_ bytes: [UInt8], _ p: inout Int, _ hi: Int) -> [String: String] {
        var result: [String: String] = [:]
        while p < hi {
            let c = bytes[p]
            if c == comma { return result }
            if isBlank(c) { p += 1; continue }
            let keyStart = p
            while p < hi && bytes[p] != equals && bytes[p] != comma && !isBlank(bytes[p]) { p += 1 }
            let keyEnd = p
            guard p < hi, bytes[p] == equals else { continue }   // ensamt ord utan värde: hoppa över
            p += 1
            let valueStart: Int
            let valueEnd: Int
            if p < hi && bytes[p] == quote {
                p += 1
                valueStart = p
                while p < hi && bytes[p] != quote { p += 1 }
                valueEnd = p
                if p < hi { p += 1 }
            } else {
                valueStart = p
                while p < hi && bytes[p] != comma && !isBlank(bytes[p]) { p += 1 }
                valueEnd = p
            }
            if keyEnd > keyStart {
                result[string(bytes, keyStart, keyEnd)] = string(bytes, valueStart, valueEnd)
            }
        }
        return result
    }
}
