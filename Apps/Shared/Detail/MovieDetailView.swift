import Core
import Library
import Personal
import Playback
import PlaybackCore
import SwiftUI

/// Detaljsida för en film (`TitleDetailScreen`): backdrop med förhandsvisning, uppgifter, "Spela" eller "Fortsätt ·
/// 32 min kvar" plus "Från början" (bara med sparad position), Min lista och 👍/👎, personer och "Liknande titlar".
/// Utan metadata, backdrop eller logga visas leverantörens titel och affisch.
struct MovieDetailView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    let providerID: String
    /// Hems förhandsvisning när sidan öppnats därifrån.
    var sharedPreview: PreviewController?

    @State private var movie: Movie?
    @State private var loading = true
    @State private var failed = false
    @State private var presented: PlayerPresentation?
    @State private var starting = false
    @State private var extras = TitleExtrasLoader()
    @State private var hero: HeroInfo?
    /// Huvudknappens text och om "Från början" visas, räknade när förloppet läses (inte vid ritning).
    @State private var playLabel = String(localized: "Play")
    @State private var hasResume = false
    /// Barnprofil och titeln klarar inte åldersfiltret.
    @State private var denied = false

    private struct HeroTrigger: Equatable {
        let loaded: Bool
        let hasMetadata: Bool
    }

    private var item: Library.LibraryItem? {
        movie.map {
            Library.LibraryItem(kind: .movie, providerID: $0.providerID, title: $0.title, year: $0.year,
                                posterURL: $0.posterURL)
        }
    }

    var body: some View {
        Group {
            if denied {
                Text("This title is not available for this profile.").foregroundStyle(.secondary).padding()
                    .stopsSharedPreview(sharedPreview, playlistID: playlistID)
            } else if let movie, let item {
                TitleDetailScreen(item: item,
                                  hero: DetailPresentation.displayHero(hero, item: item, container: movie.container),
                                  detail: extras.detail, similar: extras.similar, playlistID: playlistID,
                                  sharedPreview: sharedPreview, playerActive: presented != nil) {
                    actions
                } episodes: {
                    EmptyView()
                }
            } else if loading {
                ProgressView().padding()
                    .stopsSharedPreview(sharedPreview, playlistID: playlistID)
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
                .stopsSharedPreview(sharedPreview, playlistID: playlistID)
            }
        }
        .navigationTitle(Text(verbatim: movie?.title ?? ""))
        .playerCover($presented, playlistID: playlistID, onDismiss: refreshProgress)
        .task { await load() }
        .task { startExtras() }
        .task(id: HeroTrigger(loaded: movie != nil, hasMetadata: extras.detail?.hasMetadata == true)) {
            await loadHero()
        }
        .onDisappear { extras.cancel() }
    }

    @ViewBuilder
    private var actions: some View {
        Button { play(fromStart: false) } label: {
            Label(playLabel, systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(starting)
        if hasResume {
            Button { play(fromStart: true) } label: {
                Label("Play from Beginning", systemImage: "backward.end.fill")
            }
            .buttonStyle(.bordered)
            .disabled(starting)
        }
        PersonalButtons(ref: ItemRef(kind: .movie, providerID: providerID))
    }

    private func load() async {
        guard await model.canOpenTitle(kind: .movie, providerID: providerID, playlistID: playlistID) else {
            denied = true
            loading = false
            return
        }
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

    /// TMDB-uppgifter (kan ta en stund första gången) och liknande titlar, parallellt och oberoende av varandra.
    private func startExtras() {
        let model = model, playlistID = playlistID, providerID = providerID
        extras.start(
            detail: { await model.titleDetail(kind: .movie, providerID: providerID, playlistID: playlistID) },
            similar: { await model.similarTitles(kind: .movie, providerID: providerID, playlistID: playlistID) })
    }

    /// Hero ur databasen (backdrop, logga, märken). Läses om när TMDB-uppgifterna hämtats.
    private func loadHero() async {
        guard let item, !denied else { return }
        let found = await model.hero(for: item, playlistID: playlistID)
        guard !Task.isCancelled else { return }
        hero = found
    }

    private func refreshProgress() {
        let progress = model.userState.progress(for: ProgressKey(playlistID: playlistID, kind: .movie,
                                                                 providerID: providerID))
        if let resume = ProgressPolicy.resumePosition(progress) {
            hasResume = true
            let remaining = progress?.duration.map { $0 - resume }
            playLabel = DetailPresentation.continueLabel(episode: nil, remaining: remaining)
        } else {
            hasResume = false
            playLabel = String(localized: "Play")
        }
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
