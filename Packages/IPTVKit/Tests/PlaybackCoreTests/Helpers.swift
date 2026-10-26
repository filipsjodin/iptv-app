import Foundation
@testable import Core
@testable import PlaybackCore

let pid = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func key(_ id: String, series: String? = nil) -> ProgressKey {
    ProgressKey(playlistID: pid, kind: series == nil ? .movie : .series, providerID: id, seriesProviderID: series)
}
let k = key("m1")
let liveKey = ProgressKey(playlistID: pid, kind: .live, providerID: "l1", seriesProviderID: nil)

func t(_ id: String, _ lang: String?, ch: Int? = nil, atmos: Bool = false, def: Bool = false) -> MediaTrack {
    MediaTrack(id: id, kind: .audio, languageCode: lang, title: id, codec: nil, channelCount: ch, isAtmos: atmos, isDefault: def, isForced: false)
}
func s(_ id: String, _ lang: String?, forced: Bool = false) -> MediaTrack {
    MediaTrack(id: id, kind: .subtitle, languageCode: lang, title: id, codec: nil, channelCount: nil, isAtmos: false, isDefault: false, isForced: forced)
}
func p(id: String = "m1", series: String? = nil, position: Double, duration: Double?, watched: Bool = false, at: Date = t0) -> WatchProgress {
    WatchProgress(key: key(id, series: series), position: position, duration: duration, watched: watched, updatedAt: at)
}
func ep(_ id: String, _ season: Int, _ number: Int, series: String = "S") -> Episode {
    Episode(providerID: id, seriesProviderID: series, season: season, number: number, title: id, locator: .template("http://x/\(id)"))
}
