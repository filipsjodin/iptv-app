import Foundation

public protocol CredentialStore: Sendable {
    func save(_ secret: PlaylistSecret, for id: UUID) throws
    func load(for id: UUID) throws -> PlaylistSecret?
    func delete(for id: UUID) throws
    func allPlaylistIDs() throws -> [UUID]
}

/// För tester och previews.
// @unchecked Sendable: all åtkomst till `secrets` sker under `lock`.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: PlaylistSecret] = [:]

    public init() {}

    public func save(_ secret: PlaylistSecret, for id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        secrets[id] = secret
    }

    public func load(for id: UUID) throws -> PlaylistSecret? {
        lock.lock(); defer { lock.unlock() }
        return secrets[id]
    }

    public func delete(for id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        secrets[id] = nil
    }

    public func allPlaylistIDs() throws -> [UUID] {
        lock.lock(); defer { lock.unlock() }
        return Array(secrets.keys)
    }
}
