import SwiftUI

@main
struct IPTViOSApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            PlaylistsView()
                .environment(model)
        }
    }
}
