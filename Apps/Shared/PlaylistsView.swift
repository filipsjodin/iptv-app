import Core
import Library
import SwiftUI

/// Startvy: spellistor med antal, senaste import och kontoinformation, plus "Lägg till", "Uppdatera" och
/// inställningar.
struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAdd = false
    /// Spellistan som väntar på vuxen-PIN innan den tas bort.
    @State private var pinForRemoval: Playlist?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Add Playlist", systemImage: "plus") { showingAdd = true }
                    Button("Refresh All", systemImage: "arrow.clockwise") {
                        Task { await model.refreshAll() }
                    }
                    .disabled(model.playlists.isEmpty)
                    #if os(tvOS)
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    #endif
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
                                        account: model.accountInfo[playlist.id],
                                        phase: model.importState[playlist.id],
                                        importing: model.isImporting(playlist.id))
                        }
                        .contextMenu {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await model.refresh(playlist.id) }
                            }
                            if model.canManageProfiles(playlistID: playlist.id) {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    requestRemoval(of: playlist)
                                }
                            }
                        }
                        #if os(iOS)
                        .swipeActions {
                            if model.canManageProfiles(playlistID: playlist.id) {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    requestRemoval(of: playlist)
                                }
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
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            #endif
            .sheet(isPresented: $showingAdd) {
                AddPlaylistView()
            }
            .sheet(item: $pinForRemoval) { playlist in
                // Samma vuxen-PIN som profilhanteringen; rätt kod tar bort spellistan.
                PinEntryView(adultPinFor: playlist.id) { code in
                    remove(playlist, adultPin: code)
                }
            }
            .alert("Something went wrong", isPresented: errorPresented) {
                Button("OK", role: .cancel) { model.lastError = nil }
            } message: {
                Text(model.lastError ?? "")
            }
            .task { await model.load() }
        }
    }

    /// Frågar efter vuxen-PIN när den krävs (samma regel som profilhanteringen), annars tas spellistan bort direkt.
    private func requestRemoval(of playlist: Playlist) {
        if model.adultPinRequired(playlistID: playlist.id) {
            pinForRemoval = playlist
        } else {
            remove(playlist, adultPin: nil)
        }
    }

    private func remove(_ playlist: Playlist, adultPin: String?) {
        Task {
            do {
                try await model.remove(playlistID: playlist.id, adultPin: adultPin)
            } catch {
                model.lastError = UserFacingError.message(for: error)
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let counts: [ContentKind: Int]?
    let account: PlaylistAccountInfo?
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
            if let expires = account?.expiresAt {
                Text("Expires \(expires.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let limit = account?.maxConnections {
                Text("Max \(limit) connections")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if importing, let phase {
                ImportProgressView(phase: phase)
            }
        }
    }
}
