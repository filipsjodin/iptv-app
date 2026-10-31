import Foundation

/// Avkodar undertextfiler till text. Kastar aldrig: BOM-styrd UTF-8/UTF-16, annars strikt UTF-8, annars Windows-1252.
public enum SubtitleDecoder {
    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return "" }

        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return decodeUTF8OrFallback(Array(bytes.dropFirst(3)))
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return decodeUTF16(Array(bytes.dropFirst(2)), bigEndian: false)
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return decodeUTF16(Array(bytes.dropFirst(2)), bigEndian: true)
        }
        return decodeUTF8OrFallback(bytes)
    }

    private static func decodeUTF8OrFallback(_ bytes: [UInt8]) -> String {
        if let s = String(data: Data(bytes), encoding: .utf8) { return s }
        return decodeCp1252(bytes)
    }

    private static func decodeUTF16(_ bytes: [UInt8], bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let a = UInt16(bytes[i]), b = UInt16(bytes[i + 1])
            units.append(bigEndian ? (a << 8 | b) : (b << 8 | a))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)   // ogiltiga par blir U+FFFD
    }

    /// 0x80–0x9F i Windows-1252; resten (0x00–0x7F, 0xA0–0xFF) är identiskt med Latin-1.
    private static let cp1252High: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    static func decodeCp1252(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for b in bytes {
            let v: UInt32 = (0x80...0x9F).contains(b) ? cp1252High[Int(b) - 0x80] : UInt32(b)
            scalars.append(Unicode.Scalar(v) ?? "\u{FFFD}")
        }
        return String(scalars)
    }
}
