import Testing
import Foundation
@testable import Subtitles

func fixtureData(_ name: String, _ ext: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

struct SubtitleDecoderTests {
    @Test func decodesCp1252SwedishLetters() throws {
        let text = SubtitleDecoder.decode(try fixtureData("sample-sv-cp1252", "srt"))
        #expect(text.contains("Hej där, världen!"))
        #expect(text.contains("Åäö ÅÄÖ"))
    }

    @Test func decodesUtf8WithBOM() throws {
        let text = SubtitleDecoder.decode(try fixtureData("sample-utf8-bom", "srt"))
        #expect(!text.hasPrefix("\u{FEFF}"))
        #expect(text.hasPrefix("1\n"))
        #expect(text.contains("Åäö ÅÄÖ"))
    }

    @Test func decodesUtf16LEAndBE() throws {
        let le = SubtitleDecoder.decode(try fixtureData("sample-utf16le", "srt"))
        #expect(le.contains("Åäö ÅÄÖ"))
        #expect(!le.hasPrefix("\u{FEFF}"))
        var be = Data([0xFE, 0xFF])
        for u in "Hej åäö".utf16 { be.append(UInt8(u >> 8)); be.append(UInt8(u & 0xFF)) }
        #expect(SubtitleDecoder.decode(be) == "Hej åäö")
    }

    @Test func invalidUtf8FallsBackToCp1252() {
        let data = Data([0x48, 0xE4, 0x80, 0x9F, 0x20, 0xF6])   // Hä€Ÿ ö
        #expect(SubtitleDecoder.decode(data) == "Hä€Ÿ ö")
    }

    @Test func emptyDataGivesEmptyString() {
        #expect(SubtitleDecoder.decode(Data()) == "")
    }
}
