import Core
import Library
import SwiftUI

/// Startvy: spellistor med antal och senaste import, plus "Lägg till" och "Uppdatera".
struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Add Playlist", systemImage: "plus") { showingAdd = true }
                    Button("Refresh All", systemImage: "arrow.clockwise") {
                        Task { await model.refreshAll() }
                    }
                    .disabled(model.playlists.isEmpty)
                }
                Section("Playlists") {
                    if model.playlists.isEmpty {
                        Text("No playlists yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.playlists) { playlist in
                        NavigationLink {
                            LibraryBrowserView(playlist: playlist)
                        } label: {
                            PlaylistRow(playlist: playlist,
                                        counts: model.counts[playlist.id],
                                        phase: model.importState[playlist.id],
                                        importing: model.isImporting(playlist.id))
                        }
                        .contextMenu {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await model.refresh(playlist.id) }
                            }
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task { await model.remove(playlist.id) }
                            }
                        }
                        #if os(iOS)
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task { await model.remove(playlist.id) }
                            }
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await model.refresh(playlist.id) }
                            }
                        }
                        #endif
                    }
                }
            }
            .navigationTitle("IPTV")
            .sheet(isPresented: $showingAdd) {
                AddPlaylistView()
            }
            .alert("Something went wrong", isPresented: errorPresented) {
                Button("OK", role: .cancel) { model.lastError = nil }
            } message: {
                Text(model.lastError ?? "")
            }
            .task { await model.load() }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let counts: [ContentKind: Int]?
    let phase: ImportPhase?
    let importing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(playlist.name).font(.headline)
            if let counts {
                Text("\(counts[.movie] ?? 0) movies · \(counts[.series] ?? 0) series · \(counts[.live] ?? 0) channels")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let date = playlist.lastImportedAt {
                Text("Last import: \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !importing {
                Text("Not imported yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if importing, let phase {
                ImportProgressView(phase: phase)
            }
        }
    }
}
