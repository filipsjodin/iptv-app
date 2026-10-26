import Core
import Library
import Playback
import PlaybackCore
import SwiftUI

/// Detaljvy för en serie: säsongsväljare, avsnittslista med förlopp och sett-markering, och huvudknappen
/// "Fortsätt S1:E4" (eller "Spela S1:E1"). Xtream-avsnitt hämtas här första gången serien öppnas.
struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    let seriesProviderID: String

    @State private var series: Series?
    @State private var episodes: [Episode] = []
    @State private var progress: [String: WatchProgress] = [:]
    @State private var target: SeriesPlayTarget?
    @State private var season: Int?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var presented: PlayerPresentation?
    @State private var starting = false

    private var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    private var seasonEpisodes: [Episode] { episodes.filter { $0.season == season } }

    var body: some View {
        List {
            Section {
                header
            }
            if loading {
                ProgressView()
            } else if let errorMessage {
                Text(verbatim: errorMessage).foregroundStyle(.secondary)
                Button("Try Again", systemImage: "arrow.clockwise") { Task { await load() } }
            } else if episodes.isEmpty {
                Text("No episodes.").foregroundStyle(.secondary)
            } else {
                if seasons.count > 1 {
                    Picker("Season", selection: $season) {
                        ForEach(seasons, id: \.self) { s in
                            Text("Season \(s)").tag(Optional(s))
                        }
                    }
                }
                Section {
                    ForEach(seasonEpisodes, id: \.providerID) { episode in
                        EpisodeRow(episode: episode, progress: progress[episode.providerID]) {
                            play(episode)
                        }
                        .disabled(starting)
                    }
                }
            }
        }
        .navigationTitle(Text(verbatim: series?.title ?? ""))
        .playerCover($presented, playlistID: playlistID, onDismiss: refreshProgress)
        .task { await load() }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let series {
                Text(verbatim: series.title).font(.title2).bold()
                if let year = series.year {
                    Text(verbatim: String(year)).foregroundStyle(.secondary)
                }
            }
            if let target {
                let label = AppModel.episodeLabel(target.episode)
                Button {
                    play(target.episode)
                } label: {
                    if target.isContinue {
                        Label("Continue \(label)", systemImage: "play.fill")
                    } else {
                        Label("Play \(label)", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(starting)
            }
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        let store = model.store, playlistID = playlistID, seriesID = seriesProviderID
        series = try? await offMain { try store.series(playlistID: playlistID, providerID: seriesID) }
        do {
            episodes = try await model.episodes(for: seriesID, playlistID: playlistID)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
        refreshProgress()
        loading = false
    }

    /// Läser om förlopp och huvudknappens mål (t.ex. efter att spelaren stängts).
    private func refreshProgress() {
        let state = model.userState
        var map: [String: WatchProgress] = [:]
        for e in episodes {
            let key = ProgressKey(playlistID: playlistID, kind: .series, providerID: e.providerID,
                                  seriesProviderID: seriesProviderID)
            if let p = state.progress(for: key) { map[e.providerID] = p }
        }
        progress = map
        target = AppModel.seriesPlayTarget(
            episodes: episodes,
            last: state.lastWatchedEpisode(playlistID: playlistID, seriesProviderID: seriesProviderID))
        if season == nil || !seasons.contains(season ?? -1) {
            season = target?.episode.season ?? seasons.first
        }
    }

    private func play(_ episode: Episode) {
        guard !starting, presented == nil else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                let request = try await model.playbackRequest(kind: .series, providerID: episode.providerID,
                                                              seriesProviderID: seriesProviderID,
                                                              playlistID: playlistID)
                presented = PlayerPresentation(request: request,
                                               nextEpisodeProvider: model.nextEpisodeProvider(for: request))
            } catch is CancellationError {
                return
            } catch {
                model.lastError = UserFacingError.message(for: error)
            }
        }
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    let progress: WatchProgress?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "\(episode.number). \(episode.title)")
                        .lineLimit(2)
                    if let progress, !progress.watched, let duration = progress.duration, progress.position > 0 {
                        ProgressView(value: min(1, progress.position / duration))
                    }
                }
                Spacer()
                if progress?.watched == true {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("Watched"))
                }
            }
        }
    }
}
