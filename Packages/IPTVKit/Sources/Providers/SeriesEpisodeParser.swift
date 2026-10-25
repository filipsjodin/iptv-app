import Foundation

/// Plockar ut serienamn, säsong och avsnitt ur titlar som `Show S02E04`, `Show S1 E10` eller `Show 3x07`.
public enum SeriesEpisodeParser {
    public static func parse(_ title: String) -> (series: String, season: Int, episode: Int)? {
        let b = Array(title.utf8)
        let n = b.count
        var i = 0
        while i < n {
            let boundaryBefore = i == 0 || !isAlnum(b[i - 1])
            if boundaryBefore, let m = match(b, i) {
                let name = String(decoding: b[0..<i], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—:_.|"))
                if name.isEmpty { return nil }
                return (name, m.season, m.episode)
            }
            i += 1
        }
        return nil
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    private static func isAlnum(_ c: UInt8) -> Bool {
        isDigit(c) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c >= 0x80
    }

    private static func digits(_ b: [UInt8], _ p: inout Int, maxCount: Int) -> Int? {
        let s = p
        var v = 0
        while p < b.count, isDigit(b[p]) {
            if p - s >= maxCount { return nil }
            v = v * 10 + Int(b[p] - 48)
            p += 1
        }
        return p > s ? v : nil
    }

    private static func match(_ b: [UInt8], _ start: Int) -> (season: Int, episode: Int)? {
        var p = start
        let c = b[p]
        if c == 83 || c == 115 {            // S12E34 / S1 E10
            p += 1
            guard let season = digits(b, &p, maxCount: 3) else { return nil }
            while p < b.count, b[p] == 32 { p += 1 }
            guard p < b.count, b[p] == 69 || b[p] == 101 else { return nil }
            p += 1
            guard let ep = digits(b, &p, maxCount: 4) else { return nil }
            guard p == b.count || !isAlnum(b[p]) else { return nil }
            return (season, ep)
        }
        if isDigit(c) {                     // 3x07
            guard let season = digits(b, &p, maxCount: 2) else { return nil }
            guard p < b.count, b[p] == 120 || b[p] == 88 else { return nil }
            p += 1
            guard let ep = digits(b, &p, maxCount: 3) else { return nil }
            guard p == b.count || !isAlnum(b[p]) else { return nil }
            return (season, ep)
        }
        return nil
    }
}
