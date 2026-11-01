import SwiftUI

@main
struct IPTViOSApp: App {
    @UIApplicationDelegateAdaptor(OrientationAppDelegate.self) private var orientationDelegate
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PlaylistsView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    model.syncScenePhaseChanged(phase)
                    if phase == .active {
                        Task { await model.applicationDidBecomeActive() }
                    } else {
                        // Minnet av "systemet blev klart före handlern" gäller bara en väckning.
                        Task { @MainActor in DownloadSessionEvents.shared.resetLatch() }
                    }
                }
        }
    }
}
