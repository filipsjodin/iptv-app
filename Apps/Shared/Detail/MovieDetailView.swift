import Core
import Library
import Personal
import Playback
import PlaybackCore
import SwiftUI

/// Detaljvy för en film: affisch, titel, år, formatmärken och "Spela" eller "Fortsätt (mm:ss kvar)" plus
/// "Från början". Därunder Min lista och 👍/👎, TMDB-uppgifter när de finns (annars bara leverantörens titel och
/// affisch), personer och "Liknande titlar".
struct MovieDetailView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    let providerID: String

    @State private var movie: Movie?
    @State private var progress: WatchProgress?
    @State private var loading = true
    @State private var failed = false
    @State private var presented: PlayerPresentation?
    @State private var starting = false
    @State private var detail: TitleDetail?
    @State private var similar: [Library.LibraryItem] = []

    var body: some View {
        ScrollView {
            if let movie {
                content(movie)
            } else if loading {
                ProgressView().padding()
            } else {
                Group {
                    if failed {
                        Text("The library could not be read.")
                    } else {
                        Text("The title is no longer available.")
                    }
                }
                .foregroundStyle(.secondary)
                .padding()
            }
        }
        .navigationTitle(Text(verbatim: movie?.title ?? ""))
        .playerCover($presented, playlistID: playlistID, onDismiss: refreshProgress)
        .task { await load() }
        .task { await loadExtras() }
    }

    @ViewBuilder
    private func content(_ movie: Movie) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            PosterImage(url: detail?.posterURL ?? movie.posterURL)
            Text(verbatim: movie.title).font(.title).bold()
            HStack(spacing: 8) {
                if let year = movie.year {
                    Text(verbatim: String(year)).foregroundStyle(.secondary)
                }
                FormatBadges(container: movie.container, preference: model.settings.engine)
            }
            if let resume = ProgressPolicy.resumePosition(progress) {
                if let duration = progress?.duration {
                    ProgressView(value: min(1, resume / duration)).frame(maxWidth: 400)
                }
                Button { play(fromStart: false) } label: {
                    Label(resumeTitle(position: resume), systemImage: "play.fill")
                }
                .disabled(starting)
                Button { play(fromStart: true) } label: {
                    Label("Play from Beginning", systemImage: "backward.end.fill")
                }
                .disabled(starting)
            } else {
                Button { play(fromStart: false) } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(starting)
            }
            PersonalButtons(ref: ItemRef(kind: .movie, providerID: providerID))
            if let detail {
                TitleInfoView(detail: detail)
                PeopleShelves(detail: detail, playlistID: playlistID)
            }
            TitleShelf(title: String(localized: "Similar Titles"), items: similar, playlistID: playlistID)
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func resumeTitle(position: Double) -> String {
        guard let duration = progress?.duration else { return String(localized: "Resume") }
        let left = Int(max(0, duration - position))
        return String(localized: "Resume (\(Self.clock(left)) left)")
    }

    /// "mm:ss", eller "h:mm:ss" från en timme.
    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func load() async {
        let store = model.store, playlistID = playlistID, providerID = providerID
        do {
            movie = try await offMain { try store.movie(playlistID: playlistID, providerID: providerID) }
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
        refreshProgress()
        loading = false
    }

    /// TMDB-uppgifter (kan ta en stund första gången) och liknande titlar.
    private func loadExtras() async {
        detail = await model.titleDetail(kind: .movie, providerID: providerID, playlistID: playlistID)
        similar = await model.similarTitles(kind: .movie, providerID: providerID, playlistID: playlistID)
    }

    private func refreshProgress() {
        progress = model.userState.progress(for: ProgressKey(playlistID: playlistID, kind: .movie,
                                                             providerID: providerID))
    }

    private func play(fromStart: Bool) {
        guard !starting, presented == nil else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                let request = try await model.playbackRequest(kind: .movie, providerID: providerID,
                                                              seriesProviderID: nil, playlistID: playlistID,
                                                              startFromBeginning: fromStart)
                presented = PlayerPresentation(request: request, nextEpisodeProvider: nil)
            } catch is CancellationError {
                return
            } catch {
                model.lastError = UserFacingError.message(for: error)
            }
        }
    }
}

/// Affisch (eller en neutral platshållare).
struct PosterImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                .overlay { Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary) }
                .aspectRatio(2 / 3, contentMode: .fit)
        }
        .frame(maxWidth: 240, maxHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

/// Märken utifrån container: formatet och vilken spelare som används i automatiskt läge.
struct FormatBadges: View {
    let container: String?
    let preference: EnginePreference

    var body: some View {
        HStack(spacing: 6) {
            if let format = container?.trimmingCharacters(in: .whitespaces).uppercased(), !format.isEmpty {
                Badge(text: Text(verbatim: format))
            }
            switch EngineSelector.initial(container: container, isLive: false, preference: preference) {
            case .avPlayer: Badge(text: Text("Apple's player"))
            case .vlc: Badge(text: Text(verbatim: "VLC"))
            }
        }
    }
}

private struct Badge: View {
    let text: Text

    var body: some View {
        text.font(.caption).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
            .foregroundStyle(.secondary)
    }
}
