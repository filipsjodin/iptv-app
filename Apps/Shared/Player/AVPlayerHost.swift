import AVKit
import Playback
import SwiftUI

/// Apples spelare (`AVPlayerViewController`) för `AVPlayerEngine`.
///
/// tvOS: menyerna ligger i transportfältet och "Nästa avsnitt" som kontextuell knapp. iOS: systemets kontroller
/// med bild-i-bild och AirPlay; menyerna ligger i en egen knapp ovanpå (se `PlayerScreen`).
struct AVPlayerHost: UIViewControllerRepresentable {
    let engine: AVPlayerEngine
    let model: PlayerScreenModel

    final class Coordinator {
        var menus: [PlayerMenu] = []
        var countdown: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = engine.player
        #if os(tvOS)
        // AVPlayerEngine sköter skärmens bildfrekvens/dynamiska omfång själv.
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        #else
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        #if os(tvOS)
        // Läser `tickCount` via `menus`, så att menyerna byggs om när spår eller val ändras.
        let menus = model.menus
        if menus != context.coordinator.menus {
            context.coordinator.menus = menus
            controller.transportBarCustomMenuItems = PlayerUIMenus.make(menus)
        }
        let countdown = model.countdown
        if countdown != context.coordinator.countdown {
            context.coordinator.countdown = countdown
            controller.contextualActions = countdown.map { seconds in
                let model = model
                return [
                    UIAction(title: String(localized: "Next episode (\(seconds))")) { _ in
                        MainActor.assumeIsolated { model.playNextEpisodeNow() }
                    },
                    UIAction(title: String(localized: "Cancel")) { _ in
                        MainActor.assumeIsolated { model.cancelCountdown() }
                    },
                ]
            } ?? []
        }
        #endif
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player = nil
    }
}
