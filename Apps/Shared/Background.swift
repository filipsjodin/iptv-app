import Foundation

/// Kör synkront, potentiellt tungt arbete (databas, Keychain) utanför huvudaktören så att UI:t aldrig blockeras.
func offMain<T: Sendable>(
    priority: TaskPriority = .userInitiated, _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await Task.detached(priority: priority) { try work() }.value
}
