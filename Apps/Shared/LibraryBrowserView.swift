import Core
import Library
import Playback
import Providers
import SwiftUI

/// Bläddra i en spellistas bibliotek: Hem (upptäckt), Filmer, Serier (kategori → titlar, sidvis) och Live
/// (`LiveTabView`: kanalgrupper med tablå).
/// "Fortsätt titta" ligger överst i Filmer (bara filmer) och Serier (bara avsnitt). En titel öppnar detaljvyn; en kanal spelas direkt.
/// Alla `LibraryStore`-anrop körs utanför huvudaktören.
struct LibraryBrowserView: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    @State private var selectedTab: LibrarySection = .home

    /// Ändras när en import blir klar (AppModel laddar om spellistorna), så att vyerna läser om biblioteket.
    private var reloadKey: Date? {
        model.playlists.first { $0.id == playlist.id }?.lastImportedAt ?? playlist.lastImportedAt
    }

    /// Biblioteket visas först när en profil för spellistan är vald; annars "Vem tittar?".
    private var hasProfile: Bool { model.activeProfile?.profile.playlistID == playlist.id }

    var body: some View {
        Group {
            if hasProfile {
                library
            } else {
                WhoIsWatchingView(playlistID: playlist.id)
            }
        }
        .navigationTitle(playlist.name)
        // En ensam profil utan PIN väljs automatiskt.
        .task(id: playlist.id) { model.enter(playlistID: playlist.id) }
    }

    /// Live döljs för barnprofiler (`AppModel.libraryTabs`), på både tvOS och iOS.
    private var library: some View {
        let tabs = model.libraryTabs
        return TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: LibrarySection.home) {
                HomeView(playlistID: playlist.id, reloadKey: reloadKey)
                    .environment(\.homeTabActive, selectedTab == .home)
            }
            Tab("Movies", systemImage: "film", value: LibrarySection.movies) {
                CatalogTab(playlistID: playlist.id, kind: .movie, reloadKey: reloadKey)
            }
            Tab("Series", systemImage: "tv", value: LibrarySection.series) {
                CatalogTab(playlistID: playlist.id, kind: .series, reloadKey: reloadKey)
            }
            if tabs.contains(.live) {
                Tab("Live", systemImage: "dot.radiowaves.left.and.right", value: LibrarySection.live) {
                    LiveTabView(playlistID: playlist.id, reloadKey: reloadKey)
                }
            }
            #if !os(tvOS)
            // iOS: global sökning sist (och som sökpost i iPads sidomeny).
            Tab("Search", systemImage: "magnifyingglass", value: LibrarySection.search, role: .search) {
                SearchTabView(playlistID: playlist.id, model: model)
            }
            // Nedladdningar finns bara på iOS och döljs för barnprofiler (som Live).
            if model.downloadsAvailable, let manager = model.downloadManager {
                Tab("Downloads", systemImage: "arrow.down.circle", value: LibrarySection.downloads) {
                    DownloadsView(model: model, manager: manager, playlistID: playlist.id)
                }
            }
            #endif
        }
        #if !os(tvOS)
        .tabViewStyle(.sidebarAdaptable)
        #endif
        // Profilbyte börjar om bibliotekets vyer (positioner och listor hör till profilen).
        .id(model.activeProfile?.profile.id)
    }
}

// MARK: - Filmer och serier

private struct CatalogTab: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    let kind: ContentKind
    let reloadKey: Date?

    private struct SearchKey: Equatable {
        let query: String
        let reloadKey: Date?
    }

    @State private var categories: [Core.Category] = []
    /// Barnprofil: åldersfiltrerade rader i stället för leverantörens kategorier och "Alla".
    @State private var kidsRows: [HomeRow]?
    @State private var query = ""
    @State private var results: [Library.LibraryItem] = []
    @State private var failed = false
    @State private var continueItems: [ContinueWatchingItem] = []
    @State private var presented: PlayerPresentation?
    /// Ökas när vyn visas igen eller spelaren stängs, så att "Fortsätt titta" läses om.
    @State private var generation = 0

    private struct ContinueKey: Equatable {
        let reloadKey: Date?
        let generation: Int
    }

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContinueWatchingRow(items: continueItems) { item in
                    guard presented == nil else { return }
                    presented = PlayerPresentation(request: item.request,
                                                   nextEpisodeProvider: model.nextEpisodeProvider(for: item.request))
                }
                if let kidsRows {
                    ForEach(kidsRows) { row in
                        TitleShelf(title: row.title, items: row.titles, playlistID: playlistID)
                    }
                    if kidsRows.isEmpty, !failed {
                        Text("Nothing here yet.").foregroundStyle(.secondary)
                    }
                } else {
                    NavigationLink("All") {
                        ItemListView(playlistID: playlistID, kind: kind, categoryID: nil, title: Text("All"),
                                     reloadKey: reloadKey)
                    }
                    ForEach(categories, id: \.providerID) { category in
                        NavigationLink(category.name) {
                            ItemListView(playlistID: playlistID, kind: kind, categoryID: category.providerID,
                                         title: Text(verbatim: category.name), reloadKey: reloadKey)
                        }
                    }
                }
            } else {
                ForEach(results) { item in
                    ItemRow(item: item, playlistID: playlistID)
                }
            }
            if failed {
                Text("The library could not be read.").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query)
        .task(id: SearchKey(query: query, reloadKey: reloadKey)) { await runSearch() }
        .task(id: reloadKey) { await loadCategories() }
        .task(id: ContinueKey(reloadKey: reloadKey, generation: generation)) {
            continueItems = await model.continueWatching(playlistID: playlistID, kind: kind)
        }
        .onAppear { generation += 1 }
        .playerCover($presented, playlistID: playlistID, onDismiss: { generation += 1 })
    }

    private func loadCategories() async {
        do {
            switch try await model.catalogListing(playlistID: playlistID, kind: kind) {
            case let .categories(list):
                categories = list
                kidsRows = nil
            case let .kids(rows):
                categories = []
                kidsRows = rows
            }
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }

    /// 150 ms debounce: `.task(id:)` avbryter föregående sökning när frågan ändras.
    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        do {
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            return
        }
        // Barnprofiler: bara titlar vars åldersgräns klarar barnfiltret.
        let discovery = model.discovery, id = playlistID, kind = self.kind
        let kids = model.kidsRestricted
        let found = (try? await offMain {
            try discovery.search(q, playlistID: id, kind: kind, limit: 100, kids: kids)
        }) ?? []
        guard !Task.isCancelled else { return }
        results = found
    }
}

private struct ItemListView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    let kind: ContentKind
    let categoryID: String?
    let title: Text
    let reloadKey: Date?

    static let pageSize = 100

    /// Den import (`lastImportedAt`) som `items` kommer från; skiljer den sig från `reloadKey` laddas listan om.
    @State private var loadedKey: Date??
    @State private var items: [Library.LibraryItem] = []
    @State private var reachedEnd = false
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        content
        .navigationTitle(title)
        .task(id: reloadKey) {
            if loadedKey != .some(reloadKey) {
                loadedKey = .some(reloadKey)
                items = []
                reachedEnd = false
                failed = false
                loading = false
            }
            if items.isEmpty { await loadMore() }
        }
    }

    @ViewBuilder private var content: some View {
        #if os(tvOS)
        List {
            ForEach(items) { item in
                ItemRow(item: item, playlistID: playlistID)
                    .onAppear {
                        if item.id == items.last?.id { Task { await loadMore() } }
                    }
            }
            statusRows
        }
        #else
        PosterGridView(items: items, playlistID: playlistID, onAppearLast: { Task { await loadMore() } }) {
            statusRows
        }
        #endif
    }

    @ViewBuilder private var statusRows: some View {
        if loading {
            ProgressView()
        } else if failed {
            Text("The library could not be read.").foregroundStyle(.secondary)
        } else if reachedEnd && items.isEmpty {
            Text("Nothing here.").foregroundStyle(.secondary)
        }
    }

    private func loadMore() async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        let store = model.store, id = playlistID, kind = self.kind, categoryID = self.categoryID
        let offset = items.count
        let size = Self.pageSize
        let key = loadedKey
        do {
            let page = try await offMain {
                try store.items(playlistID: id, kind: kind, categoryID: categoryID, limit: size, offset: offset)
            }
            guard key == loadedKey else { return }   // en ny import hann bli klar; sidan är inaktuell
            items.append(contentsOf: page)
            if page.count < size { reachedEnd = true }
        } catch is CancellationError {
            // Vyn försvann; nästa visning laddar om.
        } catch {
            failed = true
            reachedEnd = true
        }
    }
}

/// En titel; öppnar film- eller seriedetaljvyn.
struct ItemRow: View {
    let item: Library.LibraryItem
    let playlistID: UUID
    var preview: PreviewController?

    var body: some View {
        NavigationLink {
            TitleDestination(kind: item.kind, providerID: item.providerID, playlistID: playlistID, preview: preview,
                             item: item)
        } label: {
            HStack {
                Text(verbatim: item.title)
                Spacer()
                if let year = item.year {
                    Text(verbatim: String(year)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Bibliotekets flikar (för flikvalet).
private enum LibrarySection: Hashable {
    case home, movies, series, live, search, downloads
}

private struct HomeTabActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Sant när Hem-fliken är vald. Hem stoppar förhandsvisningen när fliken lämnas, även med en detaljsida öppen
    /// ovanpå (då körs inte Hems `onDisappear`).
    var homeTabActive: Bool {
        get { self[HomeTabActiveKey.self] }
        set { self[HomeTabActiveKey.self] = newValue }
    }
}
