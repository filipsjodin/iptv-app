import Foundation
import PlaybackCore

/// Rena regler för nedladdningsautomatiken. Inga sidoeffekter; appen kopplar in dem.
public enum DownloadAutomation {
    /// Radera nedladdningen när titeln blivit sedd? Bara om inställningen är på och titeln nått samma gräns
    /// som appens sedd-regel (`ProgressPolicy.watchedFraction`, inklusive gränsen).
    public static func shouldDeleteAfterWatch(settings: DownloadSettings, watchedFraction: Double) -> Bool {
        settings.autoDeleteWatched && watchedFraction.isFinite && watchedFraction >= ProgressPolicy.watchedFraction
    }

    /// Avsnittet som ska köas automatiskt, eller `nil`. Bara med inställningen på, via wifi (aldrig mobildata,
    /// oavsett "bara wifi"), när inget annat är köat eller pågår och när serien inte är slut
    /// (`nextUndownloaded` är `nil` vid seriens slut).
    public static func nextEpisodeToFetch(settings: DownloadSettings, onWifi: Bool, hasQueuedOrActive: Bool,
                                          nextUndownloaded: String?) -> String? {
        guard settings.autoNextEpisode, onWifi, !hasQueuedOrActive else { return nil }
        return nextUndownloaded
    }
}
