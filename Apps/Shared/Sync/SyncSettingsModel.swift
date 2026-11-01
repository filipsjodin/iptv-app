import Foundation
import Observation

/// All logik och text för iCloud-sektionen i Inställningar, utan gränssnitt (testbar). Skapandet är billigt och har
/// inga bieffekter: i standardbygget (ingen koordinator) görs aldrig något arbete, inga skrivningar och inga anrop.
@MainActor @Observable
final class SyncSettingsModel {
    @ObservationIgnored private let app: AppModel
    /// Byter ut Keychain-växlingen i tester. Standard är `AppModel.setKeychainSyncEnabled`.
    @ObservationIgnored private let keychainSetter: (@MainActor (_ on: Bool, _ deleteCloudCopy: Bool) async throws -> Void)?

    /// En körning pågår (synk på/av, Synka nu eller Keychain-växling): alla omkopplare är låsta tills den är klar.
    private(set) var isRunning = false
    /// Visad omkopplare för iCloud Keychain. Hålls lokalt eftersom inställningen ligger i UserDefaults.
    private(set) var keychainOn: Bool
    /// "Ta bort från iCloud också?" visas.
    var isAskingAboutCloudCopy = false
    /// Frågan har ställts och väntar på svar. Rensas bara av ett svar eller Avbryt, aldrig av att dialogen stängs
    /// (knapptryck och stängning kan komma i valfri ordning). Att stänga dialogen raderar aldrig något.
    @ObservationIgnored private var pendingCloudCopyAnswer = false
    private(set) var errorMessage: String?

    init(app: AppModel,
         keychainSetter: (@MainActor (_ on: Bool, _ deleteCloudCopy: Bool) async throws -> Void)? = nil) {
        self.app = app
        self.keychainSetter = keychainSetter
        keychainOn = app.keychainSyncActive
    }

    // MARK: Tillgänglighet

    private var coordinator: SyncCoordinator? { app.syncCoordinator }

    /// Sektionen visas aldrig för barnprofiler (och inte utan aktiv profil).
    var isVisible: Bool { !app.kidsRestricted }

    /// Bygget har synk (en transport finns).
    var isAvailable: Bool { coordinator?.isAvailable == true }

    /// Förklaringen som visas när synk saknas i bygget; `nil` när synk finns.
    var unavailableExplanation: String? {
        isAvailable ? nil : String(localized: "Requires a build with iCloud (developer account)")
    }

    // MARK: Synk på/av och status

    var isSyncOn: Bool { coordinator?.isEnabled ?? false }

    private var isSyncing: Bool { coordinator?.status == .syncing }

    var syncToggleEnabled: Bool { isVisible && isAvailable && !isRunning && !isSyncing }
    var canSyncNow: Bool { isVisible && isAvailable && isSyncOn && !isRunning && !isSyncing }

    /// Statusraden, eller `nil` när det inget finns att visa (synk saknas eller är av).
    var statusText: String? {
        guard let status = coordinator?.status else { return nil }
        switch status {
        case .unavailable, .off:
            return nil
        case let .idle(lastSync):
            guard let lastSync else { return String(localized: "Not synced yet") }
            let when = lastSync.formatted(date: .abbreviated, time: .shortened)
            return String(localized: "Last synced \(when)")
        case .syncing:
            return String(localized: "Syncing…")
        case let .failed(failure):
            return Self.text(for: failure)
        }
    }

    /// Begriplig text för varje orsak till att synken misslyckats.
    static func text(for failure: SyncFailure) -> String {
        switch failure {
        case .noAccount:
            String(localized: "Not signed in to iCloud. Sign in under Settings to sync.")
        case .offline:
            String(localized: "No connection. Sync will retry automatically.")
        case .quota:
            String(localized: "Your iCloud storage is full. Free up space to keep syncing.")
        case .other:
            String(localized: "Sync failed. It will retry automatically.")
        }
    }

    func setSyncEnabled(_ on: Bool) async {
        guard syncToggleEnabled, let coordinator, on != coordinator.isEnabled else { return }
        isRunning = true
        defer { isRunning = false }
        await coordinator.setEnabled(on)
    }

    func syncNow() async {
        guard canSyncNow, let coordinator else { return }
        isRunning = true
        defer { isRunning = false }
        await coordinator.syncNow()
    }

    // MARK: iCloud Keychain

    /// Keychain-växlingen finns bara när bygget har synk; själva omkopplaren är låst om Keychain-synk saknas.
    var showsKeychainControls: Bool { isVisible && isAvailable }
    var keychainToggleEnabled: Bool {
        isVisible && isAvailable && app.keychainSyncAvailable && !isRunning && !isAskingAboutCloudCopy
    }

    /// Användaren vill slå på eller av. På: körs direkt. Av: frågar först om molnkopian (inget ändras än).
    func requestKeychain(_ on: Bool) async {
        guard keychainToggleEnabled, on != keychainOn else { return }
        if on {
            await runKeychain(true, deleteCloudCopy: false)
        } else {
            pendingCloudCopyAnswer = true
            isAskingAboutCloudCopy = true
        }
    }

    /// Svar på "Ta bort från iCloud också?". `deleteCloudCopy` raderar även de synkade kopiorna på alla enheter.
    func confirmKeychainOff(deleteCloudCopy: Bool) async {
        // Utan en ställd fråga görs ingenting. Dialogen kan redan vara stängd av systemet när knappen körs.
        guard pendingCloudCopyAnswer else { return }
        pendingCloudCopyAnswer = false
        isAskingAboutCloudCopy = false
        guard isVisible, isAvailable, app.keychainSyncAvailable, !isRunning, keychainOn else { return }
        await runKeychain(false, deleteCloudCopy: deleteCloudCopy)
    }

    /// Avbryt: omkopplaren förblir på.
    func cancelKeychainOff() {
        pendingCloudCopyAnswer = false
        isAskingAboutCloudCopy = false
    }

    /// Dialogen stängdes (utan svar än): döljer bara frågan. Avbryt-knappen kallar `cancelKeychainOff`.
    func keychainQuestionDismissed() {
        isAskingAboutCloudCopy = false
    }

    func dismissError() { errorMessage = nil }

    private func runKeychain(_ on: Bool, deleteCloudCopy: Bool) async {
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            if let keychainSetter {
                try await keychainSetter(on, deleteCloudCopy)
            } else {
                try await app.setKeychainSyncEnabled(on, deleteCloudCopy: deleteCloudCopy)
            }
            keychainOn = on
        } catch {
            errorMessage = UserFacingError.message(for: error)
            // Misslyckad flytt lämnar inställningen som den var; visa verkligt läge.
            keychainOn = app.keychainSyncActive
        }
    }

    /// Läser om visat läge (vyn visas igen).
    func refresh() {
        keychainOn = app.keychainSyncActive
    }
}

/// Texter för profiler och spellistor som väntar på inloggning från synken.
enum SyncMissingCredentials {
    /// Profil som är PIN-skyddad på en annan enhet men saknar PIN-hash här.
    static var lockedProfile: String {
        String(localized: "Requires a PIN on this device – turn on iCloud Keychain sync or set the PIN on the other device")
    }

    /// Kort etikett under den låsta profilen.
    static var lockedProfileShort: String { String(localized: "Needs PIN on this device") }

    /// Spellista från en annan enhet utan lokal inloggning.
    static var playlist: String {
        String(localized: "Sign-in missing – turn on iCloud Keychain sync or add the sign-in")
    }

    /// Förklaringen som ska visas när `select` kastar för att profilen är låst; `nil` för alla andra fel (de
    /// ignoreras som förut).
    static func lockedProfileMessage(for error: Error) -> String? {
        guard let profileError = error as? ProfileError, profileError == .pinRequiredOnThisDevice else { return nil }
        return UserFacingError.message(for: error)
    }
}
