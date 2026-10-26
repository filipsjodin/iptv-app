import Testing
import PlaybackCore
@testable import VLCEngine

@Suite struct VLCTrackMappingTests {
    @Test func mapsVLCTrackNames() {
        let t = VLCTrackMapping.tracks(from: [(-1, "Disable"), (1, "Track 1 - [Swedish]"), (2, "English (E-AC3 5.1) - Atmos")], kind: .audio)
        #expect(t.map(\.id) == ["1", "2"]); #expect(t[0].languageCode == "sv"); #expect(t[1].isAtmos); #expect(t[1].channelCount == 6)
    }

    @Test func languageFromBareCodeAndBrackets() {
        let t = VLCTrackMapping.tracks(from: [(0, "sv"), (1, "Commentary - [eng]"), (2, "Track 3"), (3, "DTS 5.1")], kind: .audio)
        #expect(t.map(\.languageCode) == ["sv", "en", nil, nil])
        #expect(t[3].channelCount == 6)
        #expect(t[2].channelCount == nil)
    }

    @Test func atmosFromJOCAndChannelLayouts() {
        let t = VLCTrackMapping.tracks(from: [(0, "English E-AC3 JOC 7.1"), (1, "Svenska Stereo"), (2, "Norwegian 2.0"), (3, "Mono")], kind: .audio)
        #expect(t[0].isAtmos)
        #expect(t[0].channelCount == 8)
        #expect(t[0].languageCode == "en")
        #expect(t[1].channelCount == 2 && t[1].languageCode == "sv")
        #expect(t[2].channelCount == 2 && t[2].languageCode == "no")
        #expect(t[3].channelCount == 1 && !t[3].isAtmos)
    }

    @Test func subtitlesKeepTitleAndForcedFlag() {
        let t = VLCTrackMapping.tracks(from: [(-1, "Disable"), (4, "Swedish Forced - [Swedish]"), (5, "Track 6 - [Finnish]")], kind: .subtitle)
        #expect(t.map(\.id) == ["4", "5"])
        #expect(t.allSatisfy { $0.kind == .subtitle && $0.channelCount == nil && !$0.isAtmos })
        #expect(t[0].isForced && !t[1].isForced)
        #expect(t[0].title == "Swedish Forced - [Swedish]")
        #expect(t[1].languageCode == "fi")
    }
}

@Suite struct VLCBufferingTests {
    @Test func bufferingIsClampedToUnitRange() {
        #expect(VLCEventRelay.normalizedBuffering(0) == 0)
        #expect(VLCEventRelay.normalizedBuffering(0.5) == 0.5)
        #expect(VLCEventRelay.normalizedBuffering(1) == 1)
        #expect(VLCEventRelay.normalizedBuffering(-0.1) == 0)
        #expect(VLCEventRelay.normalizedBuffering(100) == 1)
        #expect(VLCEventRelay.normalizedBuffering(.nan) == 0)
    }
}
