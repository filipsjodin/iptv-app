import Foundation

/// Är synk byggd in i den här appen? Styrs av build-inställningen `ICLOUD_SYNC_ENABLED` (standard `NO`), som
/// hamnar i Info.plist-nyckeln `SyncEnabled`. Utan flaggan finns ingen transport, ingen CloudKit och inga
/// entitlements, och appen beter sig exakt som före fas 7.
enum SyncAvailability {
    static let infoKey = "SyncEnabled"

    static func isAvailable(bundle: Bundle = .main) -> Bool {
        isAvailable(infoValue: bundle.object(forInfoDictionaryKey: infoKey))
    }

    /// Bara strängen `YES` slår på synk. Allt annat (`NO`, saknad nyckel, ett ej ersatt `$(…)`) är av.
    static func isAvailable(infoValue: Any?) -> Bool {
        guard let value = infoValue as? String else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES"
    }
}
