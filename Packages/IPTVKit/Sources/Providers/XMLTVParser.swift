import Foundation
import Core
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum XMLTVError: Error, Sendable, Equatable { case unreadable, malformed }

/// Strömmande XMLTV-tolk (SAX). Släpper program utanför `window` och kanaler/program som inte är önskade.
/// Program utan `stop` slutar där nästa program på samma kanal börjar; ett sista program utan `stop` släpps.
public struct XMLTVParser: Sendable {
    public let window: ClosedRange<Date>
    public let wantedChannelIDs: Set<String>?

    /// `wantedChannelIDs == nil` betyder alla kanaler.
    public init(window: ClosedRange<Date>, wantedChannelIDs: Set<String>?) {
        self.window = window
        self.wantedChannelIDs = wantedChannelIDs
    }

    public func parse(contentsOf file: URL, onChannel: (EPGChannel) -> Void, onProgram: (EPGProgram) -> Void) throws {
        guard FileManager.default.isReadableFile(atPath: file.path),
              let stream = InputStream(url: file) else { throw XMLTVError.unreadable }
        try withoutActuallyEscaping(onChannel) { onChannel in
            try withoutActuallyEscaping(onProgram) { onProgram in
                let delegate = Delegate(window: window, wanted: wantedChannelIDs, onChannel: onChannel, onProgram: onProgram)
                let xml = XMLParser(stream: stream)
                xml.delegate = delegate
                guard xml.parse() else { throw XMLTVError.malformed }
            }
        }
    }

    /// Tolkar `yyyyMMddHHmmss[ ±HHmm]` för hand. Saknad offset tolkas som UTC.
    static func parseTime(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 14 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<(from + len) {
                let c = b[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2),
              let h = num(8, 2), let mi = num(10, 2), let sec = num(12, 2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 61 else { return nil }
        var offset = 0
        var i = 14
        while i < b.count, b[i] == 32 { i += 1 }
        if i < b.count {
            let sign: Int
            switch b[i] {
            case UInt8(ascii: "+"): sign = 1
            case UInt8(ascii: "-"): sign = -1
            default: return nil
            }
            guard b.count - (i + 1) >= 4, let oh = num(i + 1, 2), let om = num(i + 3, 2) else { return nil }
            offset = sign * (oh * 3600 + om * 60)
        }
        // Dagar sedan 1970-01-01 (proleptisk gregoriansk kalender).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        let seconds = days * 86400 + h * 3600 + mi * 60 + sec - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private struct Pending {
        var start: Date
        var title: String
        var summary: String?
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let window: ClosedRange<Date>
        let wanted: Set<String>?
        let onChannel: (EPGChannel) -> Void
        let onProgram: (EPGProgram) -> Void

        // Kanalläge
        var channelID: String?
        var names: [String] = []
        // Programläge
        var progChannel: String?
        var progStart: Date?
        var progStop: Date?
        var progTitle: String?
        var progSummary: String?
        // Textinsamling
        var capturing: String?
        var text = ""
        // Program utan stop, väntar på nästa program per kanal
        var pending: [String: Pending] = [:]

        init(window: ClosedRange<Date>, wanted: Set<String>?, onChannel: @escaping (EPGChannel) -> Void, onProgram: @escaping (EPGProgram) -> Void) {
            self.window = window
            self.wanted = wanted
            self.onChannel = onChannel
            self.onProgram = onProgram
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
            switch name {
            case "channel":
                if let id = attrs["id"], wanted?.contains(id) ?? true { channelID = id; names = [] }
            case "programme":
                if let ch = attrs["channel"], wanted?.contains(ch) ?? true,
                   let start = attrs["start"].flatMap(XMLTVParser.parseTime) {
                    progChannel = ch
                    progStart = start
                    progStop = attrs["stop"].flatMap(XMLTVParser.parseTime)
                    progTitle = nil
                    progSummary = nil
                }
            case "display-name" where channelID != nil, "title" where progChannel != nil, "desc" where progChannel != nil:
                capturing = name
                text = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing != nil { text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if capturing != nil { text += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "display-name" where capturing == name:
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { names.append(t) }
                capturing = nil
            case "title" where capturing == name:
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if progTitle == nil, !t.isEmpty { progTitle = t }
                capturing = nil
            case "desc" where capturing == name:
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if progSummary == nil, !t.isEmpty { progSummary = t }
                capturing = nil
            case "channel":
                if let id = channelID { onChannel(EPGChannel(id: id, names: names)) }
                channelID = nil
            case "programme":
                finishProgramme()
            default:
                break
            }
        }

        private func finishProgramme() {
            defer { progChannel = nil; progStart = nil; progStop = nil }
            guard let ch = progChannel, let start = progStart, let title = progTitle else { return }
            // Ett väntande program på samma kanal slutar där det här börjar.
            if let p = pending.removeValue(forKey: ch) {
                emit(channel: ch, start: p.start, end: start, title: p.title, summary: p.summary)
            }
            if let stop = progStop {
                emit(channel: ch, start: start, end: stop, title: title, summary: progSummary)
            } else {
                pending[ch] = Pending(start: start, title: title, summary: progSummary)
            }
        }

        private func emit(channel: String, start: Date, end: Date, title: String, summary: String?) {
            guard end > start, end > window.lowerBound, start < window.upperBound else { return }
            onProgram(EPGProgram(channelID: channel, start: start, end: end, title: title, summary: summary))
        }
    }
}
