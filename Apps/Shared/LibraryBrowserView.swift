import Core
import Library
import Providers
import SwiftUI

/// Bläddra i en spellistas bibliotek: Filmer, Serier (kategori → titlar, sidvis) och Live (kanalgrupper).
/// Alla `LibraryStore`-anrop körs utanför huvudaktören.
struct LibraryBrowserView: View {
    let playlist: Playlist

    var body: some View {
        TabView {
            Tab("Movies", systemImage: "film") {
                CatalogTab(playlistID: playlist.id, kind: .movie)
            }
            Tab("Series", systemImage: "tv") {
                CatalogTab(playlistID: playlist.id, kind: .series)
            }
            Tab("Live", systemImage: "dot.radiowaves.left.and.right") {
                LiveTab(playlistID: playlist.id)
            }
        }
        .navigationTitle(playlist.name)
    }
}

// MARK: - Filmer och serier

private struct CatalogTab: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    let kind: ContentKind

    @State private var categories: [Core.Category] = []
    @State private var query = ""
    @State private var results: [LibraryItem] = []
    @State private var failed = false

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                NavigationLink("All") {
                    ItemListView(playlistID: playlistID, kind: kind, categoryID: nil, title: Text("All"))
                }
                ForEach(categories, id: \.providerID) { category in
                    NavigationLink(category.name) {
                        ItemListView(playlistID: playlistID, kind: kind, categoryID: category.providerID,
                                     title: Text(verbatim: category.name))
                    }
                }
            } else {
                ForEach(results) { item in
                    ItemRow(item: item)
                }
            }
            if failed {
                Text("The library could not be read.").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query)
        .task(id: query) { await runSearch() }
        .task { await loadCategories() }
    }

    private func loadCategories() async {
        let store = model.store, id = playlistID, kind = self.kind
        do {
            categories = try await offMain { try store.categories(playlistID: id, kind: kind) }
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
        let store = model.store, id = playlistID, kind = self.kind
        let found = (try? await offMain {
            try store.search(q, playlistID: id, limit: 100).filter { $0.kind == kind }
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

    static let pageSize = 100

    @State private var items: [LibraryItem] = []
    @State private var reachedEnd = false
    @State private var loading = false

    var body: some View {
        List {
            ForEach(items) { item in
                ItemRow(item: item)
                    .onAppear {
                        if item.id == items.last?.id { Task { await loadMore() } }
                    }
            }
            if loading {
                ProgressView()
            } else if reachedEnd && items.isEmpty {
                Text("Nothing here.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .task { if items.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        let store = model.store, id = playlistID, kind = self.kind, categoryID = self.categoryID
        let offset = items.count
        let size = Self.pageSize
        do {
            let page = try await offMain {
                try store.items(playlistID: id, kind: kind, categoryID: categoryID, limit: size, offset: offset)
            }
            items.append(contentsOf: page)
            if page.count < size { reachedEnd = true }
        } catch {
            reachedEnd = true
        }
    }
}

private struct ItemRow: View {
    let item: LibraryItem

    var body: some View {
        HStack {
            Text(verbatim: item.title)
            Spacer()
            if let year = item.year {
                Text(verbatim: String(year)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Live

private struct LiveTab: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID

    @State private var groups: [ChannelGroup] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if groups.isEmpty {
                Text("No channels.").foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                HStack {
                    Text(verbatim: group.displayName)
                    Spacer()
                    Text("\(group.variants.count) variants").foregroundStyle(.secondary)
                }
            }
        }
        .task {
            let store = model.store, id = playlistID
            groups = (try? await offMain { try store.channelGroups(playlistID: id) }) ?? []
            loading = false
        }
    }
}
