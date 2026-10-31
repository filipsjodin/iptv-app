import SwiftUI

@main
struct IPTViOSApp: App {
    @UIApplicationDelegateAdaptor(OrientationAppDelegate.self) private var orientationDelegate
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            PlaylistsView()
                .environment(model)
        }
    }
}
