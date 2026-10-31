#if os(iOS)
import AVKit
import SwiftUI

/// Systemets AirPlay-väljare (`AVRoutePickerView`) för Apples spelare. Visas bara på iOS; VLC kan inte
/// AirPlay-video (se `AirPlayInfoButton`).
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        view.prioritizesVideoDevices = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = String(localized: "AirPlay")
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
