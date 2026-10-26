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

    /// Håller menyernas senaste innehåll och rapporterar bild-i-bild och AVKits helskärm till modellen.
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let model: PlayerScreenModel
        var menus: [PlayerMenu] = []
        var countdownShown = false

        init(model: PlayerScreenModel) { self.model = model }

        private func update(_ change: @escaping @MainActor (PlayerScreenModel) -> Void) {
            let model = model
            MainActor.assumeIsolated { change(model) }
        }

        // Redan vid "will": vid automatisk bild-i-bild från inline kan scenens .background komma före didStart.
        nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            update { $0.pictureInPictureActive = true }
        }

        nonisolated func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            update { $0.pictureInPictureActive = true }
        }

        nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            update { $0.pictureInPictureActive = false }
        }

        nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                                              failedToStartPictureInPictureWithError error: any Error) {
            update { $0.pictureInPictureActive = false }
        }

        #if os(iOS)
        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
        ) {
            update { $0.systemFullScreenActive = true }
        }

        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
        ) {
            let model = model
            MainActor.assumeIsolated {
                coordinator.animate(alongsideTransition: nil) { context in
                    // Avbruten övergång: helskärmen ligger kvar.
                    if !context.isCancelled { MainActor.assumeIsolated { model.systemFullScreenActive = false } }
                }
            }
        }
        #endif
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = engine.player
        controller.delegate = context.coordinator
        #if os(tvOS)
        // AVPlayerEngine sköter skärmens bildfrekvens/dynamiska omfång själv.
        controller.appliesPreferredDisplayCriteriaAutomatically = false
        #else
        // AVKits egen helskärm skulle få värdvyn att försvinna; spelarvyn är redan i helskärm.
        controller.entersFullScreenWhenPlaybackBegins = false
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
        // Fasta titlar: åtgärderna sätts bara när nedräkningen börjar eller slutar. Sekunderna visas i
        // `NextEpisodeCountdownLabel`.
        let showCountdown = model.countdown != nil
        if showCountdown != context.coordinator.countdownShown {
            context.coordinator.countdownShown = showCountdown
            let model = model
            controller.contextualActions = showCountdown ? [
                UIAction(title: String(localized: "Next episode")) { _ in
                    MainActor.assumeIsolated { model.playNextEpisodeNow() }
                },
                UIAction(title: String(localized: "Cancel")) { _ in
                    MainActor.assumeIsolated { model.cancelCountdown() }
                },
            ] : []
        }
        #endif
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.delegate = nil
        controller.player = nil
    }
}
