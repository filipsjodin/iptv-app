#if !os(tvOS)
import Core
import Foundation
import Library
import Observation

/// Global sökning över filmer och serier (iOS-fliken Sök). Själva sökningen injiceras (`search`), så att modellen kan
/// testas utan databas; i appen körs den utanför huvudtråden via `offMain`.
///
/// - 150 ms debounce; varje ny fråga ogiltigförklarar föregående (generationsräknare, så ett gammalt svar aldrig
///   skriver över ett nyare även om sökningen inte hanterar avbrott).
/// - Barnprofil: `kids` skickas till sökningen och läses om efter `await`; blev profilen barn under tiden kastas
///   träffarna. Live-poster ingår aldrig.
@MainActor @Observable
final class SearchModel {
    enum Phase: Equatable {
        case idle
        case searching
        case results(movies: [Library.LibraryItem], series: [Library.LibraryItem])
        case empty
        case failed
    }

    var query = ""
    private(set) var phase: Phase = .idle

    let playlistID: UUID
    @ObservationIgnored private let search: @Sendable (String, Bool) async throws -> [Library.LibraryItem]
    @ObservationIgnored private let kids: @MainActor () -> Bool
    @ObservationIgnored private var generation = 0

    init(playlistID: UUID,
         search: @escaping @Sendable (String, Bool) async throws -> [Library.LibraryItem],
         kids: @escaping @MainActor () -> Bool) {
        self.playlistID = playlistID
        self.search = search
        self.kids = kids
    }

    func queryChanged() async {
        generation += 1
        let mine = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            phase = .idle
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }
        guard mine == generation else { return }
        phase = .searching
        let kidsAtStart = kids()
        do {
            let found = try await search(text, kidsAtStart)
            guard mine == generation, !Task.isCancelled else { return }
            // Profilen blev barn medan sökningen pågick: träffarna är inte åldersfiltrerade.
            if kids(), !kidsAtStart {
                phase = .empty
                return
            }
            let movies = found.filter { $0.kind == .movie }
            let series = found.filter { $0.kind == .series }
            phase = (movies.isEmpty && series.isEmpty) ? .empty : .results(movies: movies, series: series)
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation else { return }
            phase = .failed
        }
    }
}
#endif
