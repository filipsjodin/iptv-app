import Testing
import Foundation
import Core
import ProvidersTestSupport
@testable import Providers

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

/// Fönster 17:00-21:00 UTC den 31 oktober 2026.
private let window = utc(2026, 10, 31, 17, 0)...utc(2026, 10, 31, 21, 0)

private func run(wanted: Set<String>? = nil, file: URL? = nil) throws -> (channels: [EPGChannel], programs: [EPGProgram]) {
    var channels: [EPGChannel] = []
    var programs: [EPGProgram] = []
    let parser = XMLTVParser(window: window, wantedChannelIDs: wanted)
    try parser.parse(contentsOf: file ?? XMLTVFixtures.url(), onChannel: { channels.append($0) }, onProgram: { programs.append($0) })
    return (channels, programs)
}

@Test func parsesChannelsWithAllDisplayNames() throws {
    let r = try run()
    #expect(r.channels.map(\.id) == ["a", "b", "c"])
    #expect(r.channels[0].names == ["Alfa Ett", "Alfa 1 HD"])
    #expect(r.channels[1].names == ["Beta Två"])
    #expect(r.channels[2].names == ["Gamma Tre", "Gamma 3", "GT"])
}

@Test func parsesTimeWithPositiveAndNegativeOffsets() throws {
    let r = try run()
    let news = try #require(r.programs.first { $0.channelID == "a" && $0.title.hasPrefix("Nyheter") })
    #expect(news.start == utc(2026, 10, 31, 17, 30))
    #expect(news.end == utc(2026, 10, 31, 18, 30))
    let neg = try #require(r.programs.first { $0.title == "Negativ offset" })
    #expect(neg.start == utc(2026, 10, 31, 18, 0))
    #expect(neg.end == utc(2026, 10, 31, 19, 0))
    let none = try #require(r.programs.first { $0.title == "Utan offset" })
    #expect(none.start == utc(2026, 10, 31, 18, 30))
    #expect(none.end == utc(2026, 10, 31, 19, 30))
}

@Test func dropsProgramsOutsideWindow() throws {
    let titles = try run().programs.map(\.title)
    #expect(!titles.contains("Före fönstret"))
    #expect(!titles.contains("Efter fönstret"))
    #expect(titles.contains("Överlappar kanten"))
}

@Test func programWithoutStopEndsAtNextProgramStart() throws {
    let r = try run()
    let p = try #require(r.programs.first { $0.title == "Utan stopp" })
    #expect(p.start == utc(2026, 10, 31, 19, 0))
    #expect(p.end == utc(2026, 10, 31, 20, 0))
    #expect(!r.programs.contains { $0.title == "Sista utan stopp" })
}

@Test func wantedChannelFilterSkipsOthers() throws {
    let r = try run(wanted: ["a"])
    #expect(r.channels.map(\.id) == ["a"])
    #expect(!r.programs.isEmpty)
    #expect(r.programs.allSatisfy { $0.channelID == "a" })
}

@Test func decodesEntitiesAndTrimsText() throws {
    let r = try run()
    let news = try #require(r.programs.first { $0.channelID == "a" && $0.title.hasPrefix("Nyheter") })
    #expect(news.title == "Nyheter & Väder")
    #expect(news.summary == "Dagens nyheter.")
    let film = try #require(r.programs.first { $0.channelID == "c" })
    #expect(film.title == "Film <Special> & Co")
    #expect(film.summary == "Beskrivning med blanktecken.")
}

@Test func malformedXMLThrowsMalformed() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xmltv-\(UUID().uuidString).xml")
    try Data("<tv><channel id=\"a\"><display-name>X</tv>".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: XMLTVError.malformed) { _ = try run(file: url) }
}

@Test func missingFileThrowsUnreadable() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("finns-inte-\(UUID().uuidString).xml")
    #expect(throws: XMLTVError.unreadable) { _ = try run(file: url) }
}
