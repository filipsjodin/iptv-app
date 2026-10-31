import Testing
@testable import PlaybackCore

@Suite struct ExternalTrackTests {
    private func track(id: String) -> MediaTrack {
        MediaTrack(id: id, kind: .subtitle, languageCode: "sv", title: "t", codec: nil, channelCount: nil,
                   isAtmos: false, isDefault: false, isForced: false)
    }

    @Test func externalIDRoundTrips() {
        let id = MediaTrack.externalID(fileID: 1234)
        #expect(id == "ext:1234")
        let t = track(id: id)
        #expect(t.isExternal)
        #expect(t.externalFileID == 1234)
    }

    @Test func isExternalOnlyForExtPrefix() {
        #expect(!track(id: "0").isExternal)
        #expect(!track(id: "12").isExternal)
        #expect(!track(id: "text:5").isExternal)
        #expect(!track(id: "ext:").isExternal)
        #expect(!track(id: "ext:abc").isExternal)
        #expect(!track(id: "xext:5").isExternal)
        #expect(track(id: "0").externalFileID == nil)
    }
}
