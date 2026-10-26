import SwiftUI
import UIKit
import VLCEngine

/// VLC-motorns videoyta med SwiftUI-kontroller ovanpå.
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
