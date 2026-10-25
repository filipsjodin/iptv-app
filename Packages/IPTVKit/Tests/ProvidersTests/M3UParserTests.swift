import Testing
import Foundation
import Core
@testable import Providers

func fixture(_ name: String) throws -> String {
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    guard let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func parsesAttributesTitleAndUrl() {
    let p = M3UParser.parse("#EXTM3U url-tvg=\"http://e/x.xml\"\n#EXTINF:-1 tvg-id=\"svt1.se\" tvg-logo=\"http://l/1.png\" group-title=\"SE | Nyheter\",SE: SVT1 FHD\nhttp://h:80/live/u/p/1.m3u8\n")
    #expect(p.headerAttributes["url-tvg"] == "http://e/x.xml")
    #expect(p.entries.count == 1)
    #expect(p.entries[0].title == "SE: SVT1 FHD")
    #expect(p.entries[0].attributes["group-title"] == "SE | Nyheter")
    #expect(p.entries[0].duration == -1)
}
@Test func toleratesCRLFBomMissingHeaderAndCommasInTitle() {
    let p = M3UParser.parse("\u{FEFF}#EXTINF:-1 group-title=\"A\",Title, with comma\r\n#EXTGRP:A\r\n\r\nhttp://h/1.ts\r\n")
    #expect(p.entries.map(\.title) == ["Title, with comma"])
    #expect(p.entries[0].url == "http://h/1.ts")
}
@Test func skipsEntryWithoutUrl() {
    #expect(M3UParser.parse("#EXTM3U\n#EXTINF:-1,A\n#EXTINF:-1,B\nhttp://h/b.ts\n").entries.map(\.title) == ["B"])
}
@Test func commaInsideQuotedAttributeIsNotTitleSeparator() {
    let p = M3UParser.parse("#EXTINF:-1 tvg-name=\"A, B\" group-title=\"G\",Real Title\nhttp://h/1\n")
    #expect(p.entries[0].title == "Real Title")
    #expect(p.entries[0].attributes["tvg-name"] == "A, B")
}
@Test func parses200kEntriesLinearly() {
    let text = "#EXTM3U\n" + (0..<200_000).map { "#EXTINF:-1 group-title=\"G\",Ch \($0)\nhttp://h/u/p/\($0)\n" }.joined()
    let start = ContinuousClock.now
    #expect(M3UParser.parse(text).entries.count == 200_000)
    #expect(ContinuousClock.now - start < .seconds(10))   // generös gräns, fångar kvadratiskt beteende
}
