import Core
import Discovery
import Library
import SwiftUI

/// Hem (funktionell lista; designen kommer i fas 3b): Fortsätt titta och upptäcktens rader som vertikala
/// sektioner med horisontella listor. En titel öppnar detaljsidan; Fortsätt titta spelar direkt.
/// Raderna läses om när vyn visas igen (t.ex. efter en ändring i Min lista på en detaljsida) och när spelaren
/// stängs. Lata staplar i båda riktningarna, så att många rader inte bygger alla kort på en gång.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    let reloadKey: Date?

    @State private var rows: [HomeRow] = []
    @State private var loading = true
    @State private var failed = false
    @State private var presented: PlayerPresentation?
    /// Ökas när vyn visas igen eller spelaren stängs, så att raderna läses om.
    @State private var generation = 0

    private struct LoadKey: Equatable {
        let reloadKey: Date?
        let generation: Int
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(rows) { row in
                    if row.id == .continueWatching {
                        ContinueWatchingRow(items: row.continueItems) { item in
                            guard presented == nil else { return }
                            presented = PlayerPresentation(request: item.request,
                                                           nextEpisodeProvider: model.nextEpisodeProvider(for: item.request))
                        }
                    } else {
                        TitleShelf(title: row.title, items: row.titles, playlistID: playlistID)
                    }
                }
                if rows.isEmpty {
                    if loading {
                        ProgressView()
                    } else if failed {
                        Text("The library could not be read.").foregroundStyle(.secondary)
                    } else {
                        Text("Nothing here yet.").foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .task(id: LoadKey(reloadKey: reloadKey, generation: generation)) { await load() }
        .onAppear { generation += 1 }
        .playerCover($presented, playlistID: playlistID, onDismiss: { generation += 1 })
    }

    private func load() async {
        do {
            let loaded = try await model.homeRows(playlistID: playlistID)
            // En ersatt laddning (ny nyckel) får inte skriva över en nyare.
            guard !Task.isCancelled else { return }
            rows = loaded
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
        loading = false
    }
}

/// En rubrik och en horisontell lista med affischer. Varje affisch öppnar titelns detaljsida.
struct TitleShelf: View {
    let title: String
    let items: [Library.LibraryItem]
    let playlistID: UUID

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: title).font(.headline)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(items) { item in
                            NavigationLink {
                                TitleDestination(kind: item.kind, providerID: item.providerID, playlistID: playlistID)
                            } label: {
                                PosterCard(item: item, playlistID: playlistID)
                            }
                            #if os(tvOS)
                            .buttonStyle(.card)
                            #else
                            .buttonStyle(.plain)
                            #endif
                        }
                    }
                    .padding(.vertical, Self.focusPadding)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    #if os(tvOS)
    static let focusPadding: CGFloat = 16
    #else
    static let focusPadding: CGFloat = 4
    #endif
}

/// Affisch med titel. TMDB:s affisch när metadata finns, annars leverantörens.
struct PosterCard: View {
    @Environment(AppModel.self) private var model
    let item: Library.LibraryItem
    let playlistID: UUID

    @State private var tmdbURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: tmdbURL ?? item.posterURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
                    .overlay {
                        Image(systemName: item.kind == .series ? "tv" : "film").foregroundStyle(.secondary)
                    }
            }
            .frame(width: Self.width, height: Self.width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(verbatim: item.title).font(.caption).lineLimit(1)
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .task(id: item.id) { tmdbURL = await model.tmdbPosterURL(for: item, playlistID: playlistID) }
    }

    #if os(tvOS)
    static let width: CGFloat = 200
    #else
    static let width: CGFloat = 110
    #endif
}

/// Detaljsidan för en film eller serie (live har ingen).
struct TitleDestination: View {
    let kind: ContentKind
    let providerID: String
    let playlistID: UUID

    var body: some View {
        switch kind {
        case .movie: MovieDetailView(playlistID: playlistID, providerID: providerID)
        case .series: SeriesDetailView(playlistID: playlistID, seriesProviderID: providerID)
        case .live: EmptyView()
        }
    }
}

/// "Allt med <namn>": personens filmer och serier i spellistan.
struct PersonTitlesView: View {
    @Environment(AppModel.self) private var model
    let personID: Int
    let name: String
    let playlistID: UUID

    @State private var items: [Library.LibraryItem] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if items.isEmpty {
                Text("Nothing here.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                ItemRow(item: item, playlistID: playlistID)
            }
        }
        .navigationTitle(Text("All with \(name)"))
        .task {
            items = await model.titles(withPerson: personID, playlistID: playlistID)
            loading = false
        }
    }
}
