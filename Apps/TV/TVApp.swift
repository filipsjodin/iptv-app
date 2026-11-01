import SwiftUI

@main
struct IPTVTVApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PlaylistsView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in model.syncScenePhaseChanged(phase) }
        }
    }
}
