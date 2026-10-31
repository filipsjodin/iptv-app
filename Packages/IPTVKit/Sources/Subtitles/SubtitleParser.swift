import Foundation

/// En visad textrad med tider i sekunder.
public struct SubtitleCue: Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum SubtitleFormat: Sendable {
    case srt, vtt
}

/// Tolerant SRT/VTT-tolk. Kastar aldrig; oförståeligt innehåll hoppas över.
public enum SubtitleParser {
    public static func detectFormat(_ text: String) -> SubtitleFormat {
        var t = Substring(text)
        if t.first == "\u{FEFF}" { t = t.dropFirst() }
        return t.hasPrefix("WEBVTT") ? .vtt : .srt
    }

    public static func parse(_ text: String) -> [SubtitleCue] {
        // SRT och VTT delar cue-struktur; tidsraden ("-->") avgör var en cue börjar,
        // så huvud, index, NOTE och STYLE ignoreras av sig själva.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var cues: [SubtitleCue] = []
        var current: (start: Double, end: Double, lines: [String])?

        func flush() {
            guard let c = current else { return }
            current = nil
            let cleaned = c.lines
                .map { stripTags($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !cleaned.isEmpty else { return }
            cues.append(SubtitleCue(start: c.start, end: c.end, text: cleaned.joined(separator: "\n")))
        }

        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        func nextNonBlankIsTiming(after i: Int) -> Bool {
            var j = i + 1
            while j < lines.count, isBlank(lines[j]) { j += 1 }
            return j < lines.count && parseTimingLine(lines[j]) != nil
        }
        func startsBlock(_ s: String) -> Bool {
            for kw in ["NOTE", "STYLE", "REGION", "WEBVTT"] where s.hasPrefix(kw) {
                let rest = s.dropFirst(kw.count)
                if rest.isEmpty || rest.first == " " || rest.first == "\t" || rest.first == "-" { return true }
            }
            return false
        }

        var afterBlank = false
        for (i, line) in lines.enumerated() {
            if let (s, e) = parseTimingLine(line) {
                flush()
                current = (s, e, [])
                afterBlank = false
            } else if isBlank(line) {
                afterBlank = current != nil
            } else if current != nil {
                if afterBlank {
                    // Text efter blankrad hör till cuen om det inte är index/identifierare
                    // (följs av tidsrad) eller ett NOTE/STYLE/REGION-block.
                    if startsBlock(line) || nextNonBlankIsTiming(after: i) {
                        flush()
                        afterBlank = false
                        continue
                    }
                    afterBlank = false
                }
                current?.lines.append(line)
            }
        }
        flush()

        // Stabil sortering på start.
        return cues.enumerated()
            .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: - Hjälpare

    static func parseTimingLine(_ line: String) -> (Double, Double)? {
        guard let range = line.range(of: "-->") else { return nil }
        let left = line[line.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let rightFull = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        // VTT kan ha cue-inställningar efter sluttiden.
        let right = rightFull.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard let s = parseTimestamp(left), let e = parseTimestamp(right) else { return nil }
        return (s, e)
    }

    /// `[hh:]mm:ss[,.]mmm` → sekunder.
    static func parseTimestamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let secs = Double(parts[parts.count - 1].replacingOccurrences(of: ",", with: ".")),
              secs >= 0, secs.isFinite,
              let min = Int(parts[parts.count - 2]), min >= 0 else { return nil }
        var hours = 0
        if parts.count == 3 {
            guard let h = Int(parts[0]), h >= 0 else { return nil }
            hours = h
        }
        return Double(hours) * 3600 + Double(min) * 60 + secs
    }

    /// Tar bort `<...>`-taggar och ASS-block `{\...}`, avkodar vanliga HTML-entiteter.
    static func stripTags(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "<", let close = s[i...].firstIndex(of: ">") {
                i = s.index(after: close)
                continue
            }
            if ch == "{", s[s.index(after: i)...].hasPrefix("\\"), let close = s[i...].firstIndex(of: "}") {
                i = s.index(after: close)
                continue
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
