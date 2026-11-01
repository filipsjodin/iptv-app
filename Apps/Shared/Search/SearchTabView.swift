#if !os(tvOS)
import Core
import Library
import SwiftUI

/// Sök-fliken: en global sökning över filmer och serier i spellistan. Live ingår aldrig.
struct SearchTabView: View {
    let playlistID: UUID
    @State private var search: SearchModel

    init(playlistID: UUID, model: AppModel) {
        self.playlistID = playlistID
        let discovery = model.discovery
        _search = State(initialValue: SearchModel(
            playlistID: playlistID,
            search: { query, kids in
                // Två sökningar per typ, så att liveträffar aldrig tränger undan filmer och serier.
                async let movies = offMain {
                    try discovery.search(query, playlistID: playlistID, kind: .movie, limit: 60, kids: kids)
                }
                async let series = offMain {
                    try discovery.search(query, playlistID: playlistID, kind: .series, limit: 60, kids: kids)
                }
                return try await movies + series
            },
            kids: { [model] in model.kidsRestricted }))
    }

    var body: some View {
        // Ingen egen NavigationStack: som övriga flikar pushar affischerna på den yttre stacken (PlaylistsView).
        content
            .searchable(text: $search.query, prompt: Text("Movies and series"))
            .task(id: search.query) { await search.queryChanged() }
    }

    @ViewBuilder private var content: some View {
        switch search.phase {
        case .idle:
            ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                   description: Text("Search for movies and series."))
        case .searching:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .results(movies, series):
            PosterGridView(sections: [
                PosterGridSection(id: "movies", title: "Movies", items: movies),
                PosterGridSection(id: "series", title: "Series", items: series),
            ], playlistID: playlistID)
        case .empty:
            ContentUnavailableView.search(text: search.query)
        case .failed:
            ContentUnavailableView("The library could not be read.", systemImage: "exclamationmark.triangle")
        }
    }
}
#endif
