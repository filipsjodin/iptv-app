import Core
import Foundation
import GRDB
import Providers
import Testing

#if canImport(Darwin)
import Darwin
#endif

@testable import Library

/// Skriver en syntetisk XMLTV-fil i bitar (hela filen hålls aldrig i minnet): `channels` kanaler, `days` dagar från
/// UTC-midnatt dygnet före `now`, 40 program per dygn (36 min vardera).
private func writeXMLTV(to url: URL, channels: Int, days: Int, now: Date) throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let firstDay = cal.startOfDay(for: now.addingTimeInterval(-86_400))
    let dayStrings: [String] = (0...days).map { d in
        let c = cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: d, to: firstDay)!)
        return String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
    }
    func stamp(_ day: Int, _ minute: Int) -> String {
        let (d, m) = minute >= 1_440 ? (day + 1, minute - 1_440) : (day, minute)
        return dayStrings[d] + String(format: "%02d%02d00 +0000", m / 60, m % 60)
    }
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.write(contentsOf: Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n".utf8))
    var head = ""
    for c in 0..<channels { head += "<channel id=\"ch\(c)\"><display-name>Kanal \(c)</display-name></channel>\n" }
    try handle.write(contentsOf: Data(head.utf8))
    for c in 0..<channels {
        var chunk = ""
        for d in 0..<days {
            for k in 0..<40 {
                chunk += "<programme start=\"\(stamp(d, k * 36))\" stop=\"\(stamp(d, (k + 1) * 36))\" channel=\"ch\(c)\">"
                chunk += "<title>Program \(c)-\(d)-\(k)</title><desc>Beskrivning av programmet \(k) på kanal \(c), dag \(d).</desc></programme>\n"
            }
        }
        try handle.write(contentsOf: Data(chunk.utf8))
    }
    try handle.write(contentsOf: Data("</tv>\n".utf8))
}

/// Nuvarande resident minnesstorlek i byte, eller nil där den inte går att läsa.
private func residentBytes() -> Int? {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : nil
    #else
    return nil
    #endif
}

/// Läser resident storlek var 20:e ms på en egen tråd och sparar toppen.
private final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    private var running = true

    func start() {
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let go = running
                if let r = residentBytes() { peak = max(peak, r) }
                lock.unlock()
                if !go { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        thread.start()
    }

    func stop() -> Int {
        lock.lock(); defer { lock.unlock() }
        running = false
        return peak
    }
}

/// Seriellt: testerna mäter tid och minne och får inte konkurrera.
@Suite(.serialized) struct EPGPerformance {
    @Test func importStreamsWithBoundedMemoryAndNowNextIsFast() throws {
        let channels = 2_000
        let days = 7
        let tmp = FileManager.default.temporaryDirectory
        let xml = tmp.appendingPathComponent("perf-epg-\(UUID().uuidString).xml")
        let dbURL = tmp.appendingPathComponent("perf-epg-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: xml)
            try? FileManager.default.removeItem(at: dbURL)
        }
        let now = Date()
        try writeXMLTV(to: xml, channels: channels, days: days, now: now)
        let fileSize = (try FileManager.default.attributesOfItem(atPath: xml.path)[.size] as? Int) ?? 0
        print("PERF epg-file-size \(fileSize / 1_048_576) MB")

        let db = try AppDatabase.onDisk(at: dbURL)
        let library = LibraryStore(db: db)
        let epg = EPGStore(db: db)
        let playlist = Playlist(name: "Perf", kind: .xtream)
        try library.upsertPlaylist(playlist)

        let window = now.addingTimeInterval(-86_400)...now.addingTimeInterval(7 * 86_400)
        let baseline = residentBytes()
        let sampler = PeakSampler()
        sampler.start()
        var staged = 0
        let importTime = try ContinuousClock().measure {
            try epg.beginStaging(playlistID: playlist.id)
            var batch: [EPGProgram] = []
            func flush() throws {
                guard !batch.isEmpty else { return }
                try epg.stage(playlistID: playlist.id, programs: batch)
                staged += batch.count
                batch = []
            }
            // Ett fel i `flush` får inte tystas av tolkningens återanrop: första felet sparas och kastas efteråt.
            var flushError: Error?
            try XMLTVParser(window: window, wantedChannelIDs: nil)
                .parse(contentsOf: xml, onChannel: { _ in }, onProgram: { p in
                    batch.append(p)
                    if batch.count >= EPGImporter.batchSize {
                        do { try flush() } catch { if flushError == nil { flushError = error } }
                    }
                })
            if let flushError { throw flushError }
            try flush()
            try epg.commitStaging(playlistID: playlist.id, fetchedAt: now)
        }
        let peak = sampler.stop()
        let seconds = Double(importTime.components.seconds) + Double(importTime.components.attoseconds) / 1e18
        print("PERF epg-import \(String(format: "%.1f", seconds)) s (\(staged) program)")
        #expect(staged > channels * days * 30)
        #expect(importTime < .seconds(300))

        // Minnet får inte växa med filstorleken: en DOM hade krävt flera gånger filens storlek.
        if let baseline, peak > 0 {
            let growth = max(0, peak - baseline)
            print("PERF epg-import-memory-growth \(growth / 1_048_576) MB (fil \(fileSize / 1_048_576) MB)")
            #expect(growth < 300 * 1_048_576)
        } else {
            print("PERF epg-import-memory-growth unavailable on this platform")
        }

        let ids = (0..<100).map { "ch\($0 * 20)" }
        _ = try epg.nowNext(playlistID: playlist.id, channelIDs: ids, at: now)   // värm sidcachen
        var answers: [String: NowNext] = [:]
        let queryTime = try ContinuousClock().measure {
            answers = try epg.nowNext(playlistID: playlist.id, channelIDs: ids, at: now)
        }
        let ms = Double(queryTime.components.seconds) * 1_000 + Double(queryTime.components.attoseconds) / 1e15
        print("PERF epg-nownext-100 \(String(format: "%.1f", ms)) ms")
        #expect(answers.count == ids.count)
        #expect(answers.values.allSatisfy { $0.now != nil })
        #expect(queryTime < .milliseconds(50))
    }
}
