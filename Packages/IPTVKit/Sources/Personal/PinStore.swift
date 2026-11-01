import Foundation

public protocol ProfilePinStore: Sendable {
    func setPin(_ pin: String?, profileID: UUID) throws
    func verify(_ pin: String, profileID: UUID) throws -> Bool
    func removePin(profileID: UUID) throws
    /// Finns en PIN-hash för profilen på den här enheten? (Utan att läsa ut den.)
    func hasPin(profileID: UUID) throws -> Bool
}

/// Endast för tester: lagrar PIN som klartext i minnet. Produktion använder ett hashat Keychain-lager (Task 2).
public final class InMemoryProfilePinStore: ProfilePinStore, @unchecked Sendable {
    // @unchecked Sendable: `pins` skyddas av `lock`.
    private let lock = NSLock()
    private var pins: [UUID: String] = [:]
    public init() {}

    public func setPin(_ pin: String?, profileID: UUID) throws { lock.withLock { pins[profileID] = pin } }
    public func verify(_ pin: String, profileID: UUID) throws -> Bool { lock.withLock { pins[profileID] == pin } }
    public func removePin(profileID: UUID) throws { lock.withLock { pins[profileID] = nil } }
    public func hasPin(profileID: UUID) throws -> Bool { lock.withLock { pins[profileID] != nil } }
}
