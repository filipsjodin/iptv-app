import Foundation
import Security

/// Vilka Keychain-poster en operation gäller.
/// - `local`: poster som INTE är synkroniserbara. Frågan saknar `kSecAttrSynchronizable`, alltså exakt som
///   före fas 7, så befintliga poster hittas oförändrat.
/// - `cloud`: bara synkroniserbara poster (`kSecAttrSynchronizable = true`).
/// - `any`: båda sorterna (`kSecAttrSynchronizableAny`).
enum KeychainScope: Sendable { case local, cloud, any }

/// Delad Keychain-logik för de synkbara lagren (spellistornas inloggningar och profil-PIN). Hemligheter hanteras
/// bara som `Data` och hamnar aldrig i fel (`KeychainError` bär endast `OSStatus`).
///
/// Säkerhetsordning vid flytt mellan lokal och synkad kopia: skriv målet, läs tillbaka och jämför, ta först
/// därefter bort källan. Efter varje enskilt steg finns minst en läsbar kopia, och läsning i synkat läge hittar
/// båda sorterna.
enum KeychainItems {
    /// Verifieringen efter skrivning gav inte tillbaka det som skrevs.
    static let verificationFailed: OSStatus = errSecInternalError

    struct Item {
        let data: Data
        let modified: Date?
    }

    static func query(service: String, account: String?, scope: KeychainScope) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        switch scope {
        case .local: break
        case .cloud: q[kSecAttrSynchronizable as String] = true
        case .any: q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        return q
    }

    /// Läser värdet. För `.local` är frågan identisk med den gamla.
    static func data(service: String, account: String, scope: KeychainScope) throws -> Data? {
        var q = query(service: service, account: account, scope: scope)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return data
    }

    /// Värde och ändringsdatum (för att avgöra vilken kopia som är nyast vid flytt).
    static func item(service: String, account: String, scope: KeychainScope) throws -> Item? {
        var q = query(service: service, account: account, scope: scope)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let row = out as? [String: Any],
              let data = row[kSecValueData as String] as? Data
        else { throw KeychainError(status: status == errSecSuccess ? verificationFailed : status) }
        return Item(data: data, modified: row[kSecAttrModificationDate as String] as? Date)
    }

    /// Lägger till eller uppdaterar posten i exakt det omfång som anges (`.any` behandlas som `.cloud`). En lokal
    /// och en synkad post med samma konto är olika poster, så de krockar aldrig.
    static func write(service: String, account: String, data: Data, scope: KeychainScope) throws {
        let target: KeychainScope = scope == .local ? .local : .cloud
        var add = query(service: service, account: account, scope: target)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw KeychainError(status: status) }
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let u = SecItemUpdate(query(service: service, account: account, scope: target) as CFDictionary,
                              update as CFDictionary)
        guard u == errSecSuccess else { throw KeychainError(status: u) }
    }

    /// OBS: `.cloud` och `.any` raderar den synkade posten på ALLA användarens enheter.
    static func delete(service: String, account: String, scope: KeychainScope) throws {
        let status = SecItemDelete(query(service: service, account: account, scope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Kontonamn för tjänsten (utan dubbletter, ordning bevaras).
    static func accounts(service: String, scope: KeychainScope) throws -> [String] {
        var q = query(service: service, account: nil, scope: scope)
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { throw KeychainError(status: status) }
        var seen = Set<String>()
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter { seen.insert($0).inserted }
    }

    // MARK: Lägesberoende åtkomst

    /// Synkat läge: den synkade kopian går före den lokala (båda hittas). Annars bara lokala poster.
    static func load(service: String, account: String, synchronizable: Bool) throws -> Data? {
        guard synchronizable else { return try data(service: service, account: account, scope: .local) }
        // Två varv: en flytt (lokal -> synkad eller tvärtom) som pågår mellan de två läsningarna kan annars ge ett
        // falskt "saknas". Varje flytt skriver målet före källan tas bort och är engångs, så andra varvet träffar.
        for _ in 0..<2 {
            if let cloud = try data(service: service, account: account, scope: .cloud) { return cloud }
            if let local = try data(service: service, account: account, scope: .local) { return local }
        }
        return nil
    }

    /// Synkat läge skriver den synkade kopian och tar sedan (efter lyckad skrivning) bort en inaktuell lokal
    /// kopia, så att en läsning aldrig kan ge ett gammalt värde. Lokalt läge skriver som förut.
    static func store(service: String, account: String, data: Data, synchronizable: Bool) throws {
        guard synchronizable else {
            try write(service: service, account: account, data: data, scope: .local)
            return
        }
        try write(service: service, account: account, data: data, scope: .cloud)
        try? delete(service: service, account: account, scope: .local)
    }

    /// Synkat läge raderar båda kopiorna (den synkade försvinner på alla enheter, som en användarborttagning ska).
    static func remove(service: String, account: String, synchronizable: Bool) throws {
        try delete(service: service, account: account, scope: synchronizable ? .any : .local)
    }

    static func list(service: String, synchronizable: Bool) throws -> [String] {
        try accounts(service: service, scope: synchronizable ? .any : .local)
    }

    // MARK: Flytt

    /// Kopierar `account` från `from` till `to` och verifierar att målet kan läsas. Finns målet redan med annat
    /// värde vinner den nyaste kopian (ändringsdatum); saknas datum behålls målet. Källan rörs inte.
    private static func copy(service: String, account: String, from: KeychainScope, to: KeychainScope) throws {
        guard let source = try item(service: service, account: account, scope: from) else { return }
        let existing = try item(service: service, account: account, scope: to)
        var mustWrite = true
        if let existing {
            if existing.data == source.data {
                mustWrite = false
            } else {
                mustWrite = (source.modified ?? .distantPast) > (existing.modified ?? .distantPast)
            }
        }
        guard mustWrite else { return }
        try write(service: service, account: account, data: source.data, scope: to)
        guard let back = try data(service: service, account: account, scope: to), back == source.data else {
            throw KeychainError(status: verificationFailed)
        }
    }

    /// Lokal kopia -> synkad kopia -> verifiera -> ta bort lokal kopia. Idempotent: avbrott lämnar minst en
    /// läsbar kopia och nästa anrop fortsätter där det slutade.
    static func migrateToCloud(service: String) throws {
        for account in try accounts(service: service, scope: .local) {
            try copy(service: service, account: account, from: .local, to: .cloud)
            try delete(service: service, account: account, scope: .local)
        }
    }

    /// Synkad kopia -> lokal kopia -> verifiera -> (valfritt) ta bort den synkade kopian.
    /// VARNING: att radera den synkade kopian raderar den på ALLA användarens enheter.
    static func stopSyncing(service: String, deleteCloudCopy: Bool) throws {
        for account in try accounts(service: service, scope: .cloud) {
            try copy(service: service, account: account, from: .cloud, to: .local)
            if deleteCloudCopy { try delete(service: service, account: account, scope: .cloud) }
        }
    }
}

/// Inställningen "iCloud Keychain" (av som standard). Lagren läser den lazy per anrop via `provider`.
public struct KeychainSyncPreference: @unchecked Sendable {
    public static let key = "sync.keychain.enabled.v1"
    // @unchecked Sendable: UserDefaults är trådsäkert.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    /// Är synkat läge på? Alltid falskt när bygget saknar synk (`available == false`), även om nyckeln skulle
    /// vara satt: standardbygget använder aldrig synkroniserbara poster.
    public static func provider(defaults: UserDefaults, available: Bool) -> @Sendable () -> Bool {
        let preference = KeychainSyncPreference(defaults: defaults)
        return { available && preference.isEnabled }
    }
}
