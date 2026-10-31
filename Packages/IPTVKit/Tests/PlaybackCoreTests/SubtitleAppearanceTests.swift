import Foundation
import Testing
@testable import PlaybackCore

@Suite struct SubtitleAppearanceTests {
    @Test func appearanceDefaults() {
        let a = SubtitleAppearance()
        #expect(a.size == .medium)
        #expect(a.palette == .white)
        #expect(a.background == .shadow)
        #expect(PlaybackSettings().subtitleAppearance == a)
    }

    @Test func appearanceDecodesFromOldSettingsBlob() throws {
        // En blob sparad före fas 5: saknar nyckeln subtitleAppearance.
        let old = #"{"engine":"vlc","tracks":{},"previewsEnabled":false,"previewSoundEnabled":true}"#
        let s = try JSONDecoder().decode(PlaybackSettings.self, from: Data(old.utf8))
        #expect(s.engine == .vlc)
        #expect(s.previewsEnabled == false)
        #expect(s.subtitleAppearance == SubtitleAppearance())
    }

    @Test func appearanceRoundTrips() throws {
        var s = PlaybackSettings()
        s.subtitleAppearance = SubtitleAppearance(size: .extraLarge, palette: .cyan, background: .box)
        let back = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(s))
        #expect(back.subtitleAppearance == s.subtitleAppearance)
    }

    @Test func partialAppearanceFillsMissingFieldsWithDefaults() throws {
        let blob = #"{"subtitleAppearance":{"size":"large"}}"#
        let s = try JSONDecoder().decode(PlaybackSettings.self, from: Data(blob.utf8))
        #expect(s.subtitleAppearance == SubtitleAppearance(size: .large, palette: .white, background: .shadow))
    }

    @Test func unknownRawValuesFallBackToDefaults() throws {
        let blob = #"{"subtitleAppearance":{"size":"huge","palette":"pink","background":"glow"}}"#
        let s = try JSONDecoder().decode(PlaybackSettings.self, from: Data(blob.utf8))
        #expect(s.subtitleAppearance == SubtitleAppearance())
    }
}
