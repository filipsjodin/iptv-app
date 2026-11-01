#if !os(tvOS)
import SwiftUI

/// Den aktiva profilens nedladdningsinställningar. Bara iOS och bara när nedladdningar finns (inte barnprofiler).
/// Ändringarna sparas av profilsessionen och skickas till nedladdningshanteraren (`AppModel.applyDownloadSettings`).
struct DownloadSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.downloadsAvailable {
            Section("Downloads") {
                Toggle("Download over Wi-Fi only", isOn: $model.settings.downloads.wifiOnly)
                Toggle("Delete watched automatically", isOn: $model.settings.downloads.autoDeleteWatched)
                Toggle("Download next episode automatically over Wi-Fi",
                       isOn: $model.settings.downloads.autoNextEpisode)
            }
        }
    }
}
#endif
