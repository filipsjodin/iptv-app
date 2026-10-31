import Testing
import Foundation
@testable import Subtitles

struct SubtitleParserTests {
    @Test func parsesBasicSrt() {
        let cues = SubtitleParser.parse("1\n00:00:01,000 --> 00:00:03,500\nHej\n\n2\n01:00:04,250 --> 01:00:06,000\nDa\n")
        #expect(cues == [SubtitleCue(start: 1, end: 3.5, text: "Hej"), SubtitleCue(start: 3604.25, end: 3606, text: "Da")])
    }

    @Test func parsesDotInsteadOfCommaInTimestamp() {
        let cues = SubtitleParser.parse("1\n00:00:01.500 --> 00:00:02.000\nHej\n")
        #expect(cues.first?.start == 1.5)
    }

    @Test func parsesWithoutIndexLines() {
        let cues = SubtitleParser.parse("00:00:01,000 --> 00:00:02,000\nA\n\n00:00:03,000 --> 00:00:04,000\nB")
        #expect(cues.map(\.text) == ["A", "B"])
    }

    @Test func handlesCRLF() {
        let cues = SubtitleParser.parse("1\r\n00:00:01,000 --> 00:00:02,000\r\nA\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nB\r\n")
        #expect(cues.map(\.text) == ["A", "B"])
    }

    @Test func keepsMultilineCueText() {
        let cues = SubtitleParser.parse("1\n00:00:01,000 --> 00:00:02,000\nRad ett\nRad två\n")
        #expect(cues.first?.text == "Rad ett\nRad två")
    }

    @Test func stripsHtmlAndFontTags() {
        let cues = SubtitleParser.parse("1\n00:00:01,000 --> 00:00:02,000\n<i>Kursiv</i> <font color=\"#fff\">färg</font> {\\an8}x\n")
        #expect(cues.first?.text == "Kursiv färg x")
    }

    @Test func dropsEmptyCues() {
        let cues = SubtitleParser.parse("1\n00:00:01,000 --> 00:00:02,000\n  \n\n2\n00:00:03,000 --> 00:00:04,000\n<i></i>\n\n3\n00:00:05,000 --> 00:00:06,000\nKvar\n")
        #expect(cues.map(\.text) == ["Kvar"])
    }

    @Test func toleratesOverlappingCuesAndSortsByStart() {
        let cues = SubtitleParser.parse("1\n00:00:05,000 --> 00:00:08,000\nB\n\n2\n00:00:01,000 --> 00:00:06,000\nA\n")
        #expect(cues.map(\.text) == ["A", "B"])
    }

    @Test func blankLineInsideCueDoesNotCrash() throws {
        let text = SubtitleDecoder.decode(try fixtureData("sample-messy", "srt"))
        let cues = SubtitleParser.parse(text)
        #expect(cues.map(\.text).contains("Kursiv och färg"))
        #expect(cues.contains { $0.text == "Rad ett\nRad två efter blankrad" })
        #expect(cues.map(\.text).contains("Utan index"))
        #expect(cues.map(\.start) == cues.map(\.start).sorted())
        _ = SubtitleParser.parse("1\n00:00:01,000 --> \n\n\n-->\n00:00:01,000 --> 00:00:0")
    }

    @Test func parsesVttWithHeaderAndCueSettings() throws {
        let text = SubtitleDecoder.decode(try fixtureData("sample", "vtt"))
        let cues = SubtitleParser.parse(text)
        #expect(cues == [SubtitleCue(start: 1.5, end: 3, text: "Första raden"),
                         SubtitleCue(start: 4, end: 5.25, text: "Andra raden\nfortsätter")])
    }

    @Test func detectsFormatFromHeader() {
        #expect(SubtitleParser.detectFormat("WEBVTT\n\n00:01.000 --> 00:02.000\nA") == .vtt)
        #expect(SubtitleParser.detectFormat("\u{FEFF}WEBVTT") == .vtt)
        #expect(SubtitleParser.detectFormat("1\n00:00:01,000 --> 00:00:02,000\nA") == .srt)
    }

    @Test func vttNoteAndStyleAfterCueAreNotAppended() {
        let vtt = "WEBVTT\n\nintro\n00:01.000 --> 00:02.000\nA\n\nNOTE kommentar\nmer not\n\nSTYLE\n::cue { color: red }\n\n00:03.000 --> 00:04.000\nB\n"
        let cues = SubtitleParser.parse(vtt)
        #expect(cues.map(\.text) == ["A", "B"])
    }
}
