import Foundation

/// Värden som kan avkodas tolerant från nummer, sträng, tom sträng, `null` eller fel typ.
protocol LenientDecodable: Sendable {
    static func lenient(from container: SingleValueDecodingContainer) -> Self?
}

extension Int: LenientDecodable {
    static func lenient(from c: SingleValueDecodingContainer) -> Int? {
        if let v = try? c.decode(Int.self) { return v }
        if let b = try? c.decode(Bool.self) { return b ? 1 : 0 }
        if let d = try? c.decode(Double.self), d.isFinite, abs(d) < 9e15 { return Int(d) }
        if let s = try? c.decode(String.self) {
            let t = s.trimmingCharacters(in: .whitespaces)
            switch t.lowercased() { case "true": return 1; case "false": return 0; default: break }
            if let v = Int(t) { return v }
            if let d = Double(t), d.isFinite, abs(d) < 9e15 { return Int(d) }
        }
        return nil
    }
}

extension Double: LenientDecodable {
    static func lenient(from c: SingleValueDecodingContainer) -> Double? {
        if let v = try? c.decode(Double.self), v.isFinite { return v }
        if let s = try? c.decode(String.self), let v = Double(s.trimmingCharacters(in: .whitespaces)), v.isFinite { return v }
        return nil
    }
}

extension String: LenientDecodable {
    /// Tom (eller blank) sträng blir `nil`.
    static func lenient(from c: SingleValueDecodingContainer) -> String? {
        let raw: String?
        if let s = try? c.decode(String.self) { raw = s }
        else if let i = try? c.decode(Int.self) { raw = String(i) }
        else if let d = try? c.decode(Double.self), d.isFinite { raw = String(d) }
        else { raw = nil }
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

@propertyWrapper
struct Lenient<T: LenientDecodable>: Decodable, Sendable {
    var wrappedValue: T?

    init(wrappedValue: T?) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.singleValueContainer() else { wrappedValue = nil; return }
        wrappedValue = T.lenient(from: c)
    }
}

typealias LenientInt = Lenient<Int>
typealias LenientDouble = Lenient<Double>
typealias LenientString = Lenient<String>

extension KeyedDecodingContainer {
    /// Saknad nyckel är giltigt för `Lenient`.
    func decode<T>(_ type: Lenient<T>.Type, forKey key: Key) throws -> Lenient<T> {
        // Anropa inte `decode(Lenient<T>.self, ...)` här: det skulle välja denna överlagring igen (oändlig rekursion).
        if contains(key) { return try Lenient<T>(from: superDecoder(forKey: key)) }
        return Lenient(wrappedValue: nil)
    }
}

/// En rad i en lista: en trasig rad blir `value == nil` i stället för att fälla hela listan.
struct LenientRow<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Lista av strängar som kan vara en array eller en kommaseparerad sträng.
struct LenientStringList: Decodable, Sendable {
    var values: [String] = []
    init() {}
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.singleValueContainer() else { return }
        if let arr = try? c.decode([LenientRow<String>].self) {
            values = arr.compactMap { $0.value }
        } else if let s = try? c.decode(String.self) {
            values = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
}
