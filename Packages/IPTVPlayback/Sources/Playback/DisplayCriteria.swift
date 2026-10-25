import AVFoundation
#if os(tvOS)
import AVKit
import UIKit
#endif

/// Plattformsneutral behållare för skärmkriterier (`AVDisplayCriteria` på tvOS).
public struct DisplayCriteria: @unchecked Sendable {
    let storage: AnyObject?

    #if os(tvOS)
    public init(_ criteria: AVDisplayCriteria) { storage = criteria }
    var value: AVDisplayCriteria? { storage as? AVDisplayCriteria }
    #endif

    private init(storage: AnyObject?) { self.storage = storage }

    /// Markör utan verklig effekt, för tester av när kriterier sätts och återställs.
    public static let placeholder = DisplayCriteria(storage: nil)
}

/// Hämtar och sätter skärmkriterier. Kan bytas ut i tester.
@MainActor
public protocol DisplayCriteriaSetting: AnyObject {
    func criteria(for asset: AVAsset) async -> DisplayCriteria?
    func set(_ criteria: DisplayCriteria?)
}

/// Standardimplementation: `DisplayCriteriaHelper` (verklig effekt bara på tvOS).
@MainActor
public final class SystemDisplayCriteria: DisplayCriteriaSetting {
    public init() {}
    public func criteria(for asset: AVAsset) async -> DisplayCriteria? { await DisplayCriteriaHelper.criteria(for: asset) }
    public func set(_ criteria: DisplayCriteria?) { DisplayCriteriaHelper.set(criteria) }
}

/// Matchar tv:ns bildfrekvens och dynamiska omfång mot innehållet (tvOS). Gör ingenting på iOS.
@MainActor
public enum DisplayCriteriaHelper {
    /// Innehållets föredragna kriterier, eller nil (alltid nil på iOS).
    public static func criteria(for asset: AVAsset) async -> DisplayCriteria? {
        #if os(tvOS)
        guard let criteria = try? await asset.load(.preferredDisplayCriteria) else { return nil }
        return DisplayCriteria(criteria)
        #else
        return nil
        #endif
    }

    public static func set(_ criteria: DisplayCriteria?) {
        #if os(tvOS)
        currentDisplayManager()?.preferredDisplayCriteria = criteria?.value
        #endif
    }

    public static func reset() { set(nil) }

    #if os(tvOS)
    private static func currentDisplayManager() -> AVDisplayManager? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow) ?? windows.first
        return window?.avDisplayManager
    }
    #endif
}
