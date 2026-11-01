#if canImport(CloudKit)
import CloudKit
import Foundation
import Sync

/// Orsak till att CloudKit-synken inte kan gå vidare. Appens `SyncFailure.classify` tolkar den.
public enum CloudSyncFailure: Error, Equatable, Sendable {
    case noAccount, offline, quota
}

/// Rena avbildningar `CKError`/kontostatus -> `CloudSyncFailure` (testas utan CloudKit-container).
public enum CloudKitFailureMapping {
    /// `nil` = inte ett känt synkfel (kastas då vidare orört).
    public static func failure(for error: Error) -> CloudSyncFailure? {
        if let known = error as? CloudSyncFailure { return known }
        guard let ck = error as? CKError else { return nil }
        switch ck.code {
        case .notAuthenticated:
            return .noAccount
        case .quotaExceeded:
            return .quota
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy,
             .accountTemporarilyUnavailable:
            return .offline
        default:
            return nil
        }
    }

    /// `nil` = kontot kan användas.
    public static func failure(forAccountStatus status: CKAccountStatus) -> CloudSyncFailure? {
        switch status {
        case .available: return nil
        case .noAccount, .restricted: return .noAccount
        case .couldNotDetermine, .temporarilyUnavailable: return .offline
        @unknown default: return .noAccount
        }
    }
}

public enum AccountChangeKind: Sendable, Equatable, CaseIterable {
    case signIn, signOut, switchAccounts
}

/// Vad transporten gör när iCloud-kontot ändras. Ingen variant rör lokal data: synk stannar eller startar om,
/// lokala lagren lämnas orörda (appen raderar aldrig användarens data på grund av ett kontobyte).
public enum AccountChangeAction: Sendable, Equatable, CaseIterable {
    /// Fortsätt (samma konto loggade in igen).
    case keepRunning
    /// Stanna och rapportera `noAccount` tills kontot är tillbaka.
    case suspendNoAccount
    /// Nytt konto: glöm motorns token (de hör till det gamla kontot), stanna. Användaren slår av/på synk (full
    /// uppladdning) och startar om appen.
    case resetEngineStateAndSuspend

    public static func action(for change: AccountChangeKind) -> AccountChangeAction {
        switch change {
        case .signIn: return .keepRunning
        case .signOut: return .suspendNoAccount
        case .switchAccounts: return .resetEngineStateAndSuspend
        }
    }

    /// Alltid falskt: kontobyte raderar aldrig lokala data.
    public var deletesLocalData: Bool { false }
}

/// CloudKit slår inte ihop på servern (till skillnad från `InMemoryCloud`): vid `serverRecordChanged` hämtas serverns
/// version, slås ihop med vår via `SyncMerge`, och bara om resultatet skiljer sig från servern skickas det igen.
public enum CloudConflictResolver {
    public struct Outcome: Equatable, Sendable {
        public var merged: SyncRecord
        public var needsResend: Bool
    }

    public static func resolve(server: SyncRecord, ours: SyncRecord?, now: Date) -> Outcome {
        guard let ours else { return Outcome(merged: server, needsResend: false) }
        let merged = CKRecordCoding.quantized(SyncMerge.merge(local: server, remote: ours, now: now))
        return Outcome(merged: merged, needsResend: merged != server)
    }
}

public enum CloudKitConfiguration {
    public static let defaultContainerIdentifier = "iCloud.se.sjodin.iptv"
    public static let infoKey = "CloudKitContainerIdentifier"

    /// Tomt, saknat eller ej ersatt `$(...)` ger standardcontainern.
    public static func containerIdentifier(infoValue: Any?) -> String {
        guard let value = (infoValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.hasPrefix("$(") else { return defaultContainerIdentifier }
        return value
    }

    public static func containerIdentifier(bundle: Bundle = .main) -> String {
        containerIdentifier(infoValue: bundle.object(forInfoDictionaryKey: infoKey))
    }

    /// `Application Support/Sync` (motorns token; utesluts ur säkerhetskopior av transporten).
    public static func defaultStateDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sync", isDirectory: true)
    }
}
#endif
