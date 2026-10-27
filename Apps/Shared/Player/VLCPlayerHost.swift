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
        .onAppear { VLCNowPlaying.show(title: engine.title, owner: ObjectIdentifier(engine)) }
        .onDisappear { VLCNowPlaying.clear(owner: ObjectIdentifier(engine)) }
    }
}

/// Now Playing för VLC: bara titeln (aldrig URL:en). Varje visning hör till en motor; bara den motorn kan
/// rensa den, så att en värdvy som försvinner efter att nästa motor (t.ex. nästa avsnitt) tagit över inte
/// tömmer den nya titeln.
@MainActor
enum VLCNowPlaying {
    private(set) static var owner: ObjectIdentifier?

    static func show(title: String?, owner: ObjectIdentifier) {
        guard let title, !title.isEmpty else { return }
        self.owner = owner
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info(title: title)
    }

    static func clear(owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        self.owner = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    nonisolated static func info(title: String) -> [String: Any] {
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
