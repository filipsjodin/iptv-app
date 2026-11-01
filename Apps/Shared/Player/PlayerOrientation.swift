#if !os(tvOS)
import SwiftUI
import UIKit

/// Vilka orienteringar appen tillåter. Ren funktion, så att den kan testas utan UIKit-tillstånd.
enum PlayerOrientationPolicy {
    /// iPhone i spelaren: bara liggande. iPad: alla fyra. Utan spelare: iPhone utom upp-och-ned, iPad alla.
    static func mask(isPlayerPresented: Bool, isPad: Bool) -> UIInterfaceOrientationMask {
        if isPad { return .all }
        return isPlayerPresented ? .landscape : .allButUpsideDown
    }
}

/// Äger orienteringstillståndet som appens delegat läser och begär geometri när spelaren öppnas och stängs.
///
/// Tillståndet är `@MainActor`: `UIApplicationDelegate`-metoderna är själva `@MainActor` i SDK:n, så delegaten
/// läser det utan `assumeIsolated`. Geometribegäran byter bara tillåten orientering; den berör aldrig sessionen,
/// så rotation, bild-i-bild och AVKits helskärm startar inte om uppspelningen.
@MainActor
final class PlayerOrientationController {
    /// Begär geometri för en mask; felhanteraren anropas om systemet nekar.
    typealias GeometryRequester = @MainActor (UIInterfaceOrientationMask, @escaping @Sendable (Error) -> Void) -> Void

    static let shared = PlayerOrientationController()

    private(set) var isPlayerPresented = false
    private let isPad: Bool
    /// Sceneens gränssnittsorientering just nu (`nil` om den inte kan avgöras).
    private let sceneIsPortrait: @MainActor () -> Bool?
    /// Orienteringen före spelaren; `nil` innan spelaren öppnats eller om den var okänd.
    private var portraitBeforePlayer: Bool?
    private let requestGeometry: GeometryRequester
    /// Uppdaterar rotvyns tillåtna orienteringar efter varje tillståndsändring.
    private let refreshSupported: @MainActor () -> Void

    init(isPad: Bool = UIDevice.current.userInterfaceIdiom == .pad,
         sceneIsPortrait: @escaping @MainActor () -> Bool? = PlayerOrientationController.sceneIsPortraitNow,
         refreshSupported: @escaping @MainActor () -> Void = PlayerOrientationController.refreshSystem,
         requestGeometry: @escaping GeometryRequester = PlayerOrientationController.requestFromScene) {
        self.isPad = isPad
        self.sceneIsPortrait = sceneIsPortrait
        self.refreshSupported = refreshSupported
        self.requestGeometry = requestGeometry
    }

    /// Masken som `application(_:supportedInterfaceOrientationsFor:)` returnerar.
    var supportedMask: UIInterfaceOrientationMask {
        PlayerOrientationPolicy.mask(isPlayerPresented: isPlayerPresented, isPad: isPad)
    }

    func playerWillAppear() {
        guard !isPlayerPresented else { return }
        // Läses före låsningen till liggande, så att vi vet vart vi ska tillbaka.
        portraitBeforePlayer = sceneIsPortrait()
        isPlayerPresented = true
        refreshSupported()
        // iPad tillåter redan alla orienteringar; en begäran skulle bara ge ignorerade fel.
        if !isPad { requestGeometry(supportedMask) { _ in } }
    }

    /// Återställer vid stängning. Tillståndet ändras först, så att en nekad geometribegäran inte lämnar
    /// spelarens låsning kvar; felet ignoreras (systemet behåller då nuvarande orientering, som ändå är tillåten).
    func playerDidClose() {
        guard isPlayerPresented else { return }
        isPlayerPresented = false
        refreshSupported()
        // Var appen stående före spelaren återgår vi dit; annars (liggande eller okänt) lämnas orienteringen åt systemet.
        let wasPortrait = portraitBeforePlayer ?? false
        portraitBeforePlayer = nil
        guard !isPad else { return }
        let target: UIInterfaceOrientationMask = wasPortrait ? .portrait : supportedMask
        requestGeometry(target) { _ in }
    }

    private static func sceneIsPortraitNow() -> Bool? {
        guard let orientation = activeScene()?.interfaceOrientation, orientation != .unknown else { return nil }
        return orientation.isPortrait
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func refreshSystem() {
        for window in activeScene()?.windows ?? [] {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    private static func requestFromScene(_ mask: UIInterfaceOrientationMask,
                                         onError: @escaping @Sendable (Error) -> Void) {
        guard let scene = activeScene() else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask), errorHandler: onError)
    }
}

/// Ger systemet den tillåtna masken från `PlayerOrientationController`.
@MainActor
final class OrientationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PlayerOrientationController.shared.supportedMask
    }

    /// Systemet väcker appen för bakgrundsnedladdningar. Handlern sparas och anropas när transporten rapporterat
    /// att alla köade händelser levererats (`DownloadSessionEvents.complete`).
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundDownloadTransport.sessionIdentifier,
              DownloadSessionEvents.shared.isTransportAttached else {
            completionHandler()
            return
        }
        DownloadSessionEvents.shared.store(completionHandler)
    }
}
#endif
