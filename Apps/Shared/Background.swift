import Foundation

/// Kör synkront, potentiellt tungt arbete (databas, Keychain) utanför huvudaktören så att UI:t aldrig blockeras.
///
/// Avbryts anroparen avbryts även den frikopplade uppgiften; arbete som inte hunnit starta körs då inte
/// (`CancellationError`). Arbete som redan körs synkront går klart. Städning som alltid måste köras (t.ex.
/// borttagning av hemligheter) skickar `honorsCancellation: false`.
func offMain<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    honorsCancellation: Bool = true,
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    let task = Task.detached(priority: priority) {
        if honorsCancellation { try Task.checkCancellation() }
        return try work()
    }
    guard honorsCancellation else { return try await task.value }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
