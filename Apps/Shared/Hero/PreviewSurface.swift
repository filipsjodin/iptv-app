import AVFoundation
import Playback
import SwiftUI
import UIKit

/// Förhandsvisningens video, utan kontroller och tyst om inte profilen tillåter ljud (kontrollern styr ljudet).
/// Läggs ovanpå backdropen (`.overlay { PreviewSurface(controller: preview) }`) och tonas in med `Motion.crossfade`
/// bara när `state == .playing`; under Minska rörelse byts bilden utan animation. I alla andra lägen är ytan tom,
/// så att backdropen syns.
struct PreviewSurface: View {
    let controller: PreviewController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if case .playing(let engine) = controller.state, let avEngine = engine as? AVPlayerEngine {
                PreviewPlayerLayer(player: avEngine.player)
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.crossfade, reduceMotion: reduceMotion), value: controller.isPlaying)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// `AVPlayerLayer` som fyller ytan (beskuren som backdropen). Fungerar likadant på tvOS och iOS.
private struct PreviewPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }
}
