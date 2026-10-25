import AVFoundation
#if os(tvOS)
import AVKit
import UIKit
#endif

/// Matchar tv:ns bildfrekvens och dynamiska omfång mot innehållet (tvOS). Gör ingenting på iOS.
@MainActor
public enum DisplayCriteriaHelper {
    public static func apply(for asset: AVAsset) async {
        #if os(tvOS)
        guard let criteria = try? await asset.load(.preferredDisplayCriteria) else { return }
        currentDisplayManager()?.preferredDisplayCriteria = criteria
        #endif
    }

    public static func reset() {
        #if os(tvOS)
        currentDisplayManager()?.preferredDisplayCriteria = nil
        #endif
    }

    #if os(tvOS)
    private static func currentDisplayManager() -> AVDisplayManager? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        return window?.avDisplayManager
    }
    #endif
}
