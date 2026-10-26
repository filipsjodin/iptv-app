import MediaPlayer
import SwiftUI
import UIKit
import VLCEngine

/// VLC-motorns videoyta med SwiftUI-kontroller ovanpå. Titeln visas i Kontrollcenter via
/// `MPNowPlayingInfoCenter` medan vyn visas (Apples spelare sköter det själv och rör aldrig den här).
struct VLCPlayerHost: View {
    let engine: VLCPlayerEngine
    let model: PlayerScreenModel
    let onClose: () -> Void

    var body: some View {
        ZStack {
            VLCDrawableView(drawable: engine.drawable)
                .ignoresSafeArea()
            PlayerControlsOverlay(model: model, onClose: onClose)
        }
        .onAppear { VLCNowPlaying.show(title: engine.title) }
        .onDisappear { VLCNowPlaying.clear() }
    }
}

/// Now Playing för VLC: bara titeln (aldrig URL:en).
enum VLCNowPlaying {
    @MainActor static func show(title: String?) {
        guard let title, !title.isEmpty else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info(title: title)
    }

    @MainActor static func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    static func info(title: String) -> [String: Any] {
        [MPMediaItemPropertyTitle: title]
    }
}

/// Placerar motorns `drawable` i en behållare som följer vyns storlek.
struct VLCDrawableView: UIViewRepresentable {
    let drawable: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        drawable.frame = container.bounds
        drawable.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(drawable)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if drawable.superview !== container {
            drawable.frame = container.bounds
            container.addSubview(drawable)
        }
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        for view in container.subviews { view.removeFromSuperview() }
    }
}
