import Foundation
#if canImport(UIKit) && !os(tvOS)
import UIKit
#endif

/// Håller appen vaken en kort stund medan arbete pågår efter att den gått till bakgrunden (iOS `beginBackgroundTask`).
/// Koordinatorn får en injicerad körare: testerna använder en fejk, standardbygget får ingen påverkan.
@MainActor
protocol SyncBackgroundTaskRunning: AnyObject {
    /// Kör `work` inom en bakgrundsuppgift som avslutas när arbetet är klart (eller tiden går ut).
    func run(_ work: @escaping @MainActor () async -> Void)
}

/// Gör ingenting extra (tester, tvOS): arbetet körs inte alls här, koordinatorn har redan startat sin push.
@MainActor
final class NoBackgroundTaskRunner: SyncBackgroundTaskRunning {
    init() {}
    func run(_ work: @escaping @MainActor () async -> Void) {}
}

#if canImport(UIKit) && !os(tvOS)
@MainActor
final class PlatformBackgroundTaskRunner: SyncBackgroundTaskRunning {
    @MainActor private final class Token {
        var id: UIBackgroundTaskIdentifier = .invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }

    init() {}

    func run(_ work: @escaping @MainActor () async -> Void) {
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "iptv.sync.flush") {
            // Körs på huvudtråden; avsluta synkront innan systemet tar appen.
            MainActor.assumeIsolated { token.end() }
        }
        guard token.id != .invalid else { return }
        Task { @MainActor in
            await work()
            token.end()
        }
    }
}
#else
typealias PlatformBackgroundTaskRunner = NoBackgroundTaskRunner
#endif
