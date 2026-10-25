import SwiftUI

@main
struct IPTVTVApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            PlaylistsView()
                .environment(model)
        }
    }
}
