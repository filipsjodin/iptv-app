import Foundation
import Testing
@testable import PlaybackCore

@Suite struct DownloadSettingsTests {
    @Test func downloadSettingsDefaultsAndOldBlobDecodes() throws {
        let d = DownloadSettings()
        #expect(d.wifiOnly == true)
        #expect(d.autoDeleteWatched == false)
        #expect(d.autoNextEpisode == false)
        #expect(PlaybackSettings().downloads == d)

        // Blob sparad före fas 6b: saknar nyckeln downloads.
        let old = #"{"engine":"vlc","tracks":{},"previewsEnabled":false,"previewSoundEnabled":true}"#
        let s = try JSONDecoder().decode(PlaybackSettings.self, from: Data(old.utf8))
        #expect(s.downloads == DownloadSettings())

        // Delvis blob och okänt värde ger standardvärden per fält.
        let partial = #"{"downloads":{"autoNextEpisode":true,"wifiOnly":"nej"}}"#
        let p = try JSONDecoder().decode(PlaybackSettings.self, from: Data(partial.utf8))
        #expect(p.downloads == DownloadSettings(wifiOnly: true, autoDeleteWatched: false, autoNextEpisode: true))

        var changed = PlaybackSettings()
        changed.downloads = DownloadSettings(wifiOnly: false, autoDeleteWatched: true, autoNextEpisode: true)
        let back = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(changed))
        #expect(back.downloads == changed.downloads)
    }
}
