import Core
import Library
import Personal
import Playback
import PlaybackCore
import SwiftUI

/// Detaljsida för en serie (`TitleDetailScreen`): backdrop med förhandsvisning (S1:E1), uppgifter, huvudknappen
/// "Fortsätt S2:E4 · 32 min kvar" (eller "Spela S1:E1"), "Från början" när avsnittet har sparad position, Min lista och
/// 👍/👎, säsongsflikar och avsnitt i en horisontell rad, personer och "Liknande titlar". Xtream-avsnitt hämtas här
/// första gången serien öppnas.
struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    let seriesProviderID: String
    /// Hems förhandsvisning när sidan öppnats därifrån.
    var sharedPreview: PreviewController?

    @State private var series: Series?
    @State private var episodes: [Episode] = []
    @State private var cardsBySeason: [Int: [EpisodeCardData]] = [:]
    @State private var target: SeriesPlayTarget?
    @State private var playLabel = ""
    @State private var hasResume = false
    @State private var season: Int?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var presented: PlayerPresentation?
    @State private var starting = false
    @State private var extras = TitleExtrasLoader()
    @State private var hero: HeroInfo?
    /// Barnprofil och serien klarar inte åldersfiltret.
    @State private var denied = false

    private struct HeroTrigger: Equatable {
        let loaded: Bool
        let hasMetadata: Bool
    }

    private var seasons: [Int] { cardsBySeason.keys.sorted() }

    private var item: Library.LibraryItem? {
        series.map {
            Library.LibraryItem(kind: .series, providerID: $0.providerID, title: $0.title, year: $0.year,
                                posterURL: $0.posterURL)
        }
    }

    var body: some View {
        Group {
            if denied {
                Text("This title is not available for this profile.").foregroundStyle(.secondary).padding()
            } else if let series, let item {
                TitleDetailScreen(item: item,
                                  hero: DetailPresentation.displayHero(hero, item: item, container: nil),
                                  detail: extras.detail, similar: extras.similar, playlistID: playlistID,
                                  sharedPreview: sharedPreview, playerActive: presented != nil) {
                    actions
                } episodes: {
                    episodeSection
                }
                .navigationTitle(Text(verbatim: series.title))
            } else if loading {
                ProgressView().padding()
            } else {
                Text("The title is no longer available.").foregroundStyle(.secondary).padding()
            }
        }
        .playerCover($presented, playlistID: playlistID, onDismiss: refreshProgress)
        .task { await load() }
        .task { startExtras() }
        .task(id: HeroTrigger(loaded: series != nil, hasMetadata: extras.detail?.hasMetadata == true)) {
            await loadHero()
        }
        .onDisappear { extras.cancel() }
    }

    @ViewBuilder
    private var actions: some View {
        if let target {
            Button { play(target.episode) } label: {
                Label(playLabel, systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(starting)
            // "Från början" när avsnittet har en sparad position att fortsätta från.
            if hasResume {
                Button { play(target.episode, fromStart: true) } label: {
                    Label("Play from Beginning", systemImage: "backward.end.fill")
                }
                .buttonStyle(.bordered)
                .disabled(starting)
            }
        }
        PersonalButtons(ref: ItemRef(kind: .series, providerID: seriesProviderID))
    }

    @ViewBuilder
    private var episodeSection: some View {
        if loading {
            ProgressView()
        } else if let errorMessage {
            Text(verbatim: errorMessage).foregroundStyle(.secondary)
            Button("Try Again", systemImage: "arrow.clockwise") { Task { await load() } }
        } else if episodes.isEmpty {
            Text("No episodes.").foregroundStyle(.secondary)
        } else {
            EpisodeShelf(seasons: seasons, season: $season, cards: cardsBySeason[season ?? -1] ?? [],
                         disabled: starting) { id in
                if let episode = episodes.first(where: { $0.providerID == id }) { play(episode) }
            }
        }
    }

    private func load() async {
        guard await model.canOpenTitle(kind: .series, providerID: seriesProviderID, playlistID: playlistID) else {
            denied = true
            loading = false
            return
        }
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

    /// TMDB-uppgifter och liknande titlar, parallellt och oberoende av varandra.
    private func startExtras() {
        let model = model, playlistID = playlistID, providerID = seriesProviderID
        extras.start(
            detail: { await model.titleDetail(kind: .series, providerID: providerID, playlistID: playlistID) },
            similar: { await model.similarTitles(kind: .series, providerID: providerID, playlistID: playlistID) })
    }

    /// Hero ur databasen (backdrop, logga, märken). Läses om när TMDB-uppgifterna hämtats.
    private func loadHero() async {
        guard let item, !denied else { return }
        let found = await model.hero(for: item, playlistID: playlistID)
        guard !Task.isCancelled else { return }
        hero = found
    }

    /// Läser om förlopp, kort och huvudknappens mål och text (t.ex. efter att spelaren stängts).
    private func refreshProgress() {
        let state = model.userState
        var progress: [String: WatchProgress] = [:]
        var cards: [Int: [EpisodeCardData]] = [:]
        for episode in episodes.sorted(by: { ($0.season, $0.number) < ($1.season, $1.number) }) {
            let key = ProgressKey(playlistID: playlistID, kind: .series, providerID: episode.providerID,
                                  seriesProviderID: seriesProviderID)
            let found = state.progress(for: key)
            if let found { progress[episode.providerID] = found }
            cards[episode.season, default: []].append(EpisodeCardData.make(episode, progress: found))
        }
        cardsBySeason = cards
        let next = AppModel.seriesPlayTarget(
            episodes: episodes,
            last: state.lastWatchedEpisode(playlistID: playlistID, seriesProviderID: seriesProviderID))
        target = next
        if let next {
            let episodeProgress = progress[next.episode.providerID]
            let resume = ProgressPolicy.resumePosition(episodeProgress)
            hasResume = resume != nil
            let label = AppModel.episodeLabel(next.episode)
            if let resume {
                let remaining = episodeProgress?.duration.map { $0 - resume }
                playLabel = DetailPresentation.continueLabel(episode: label, remaining: remaining)
            } else if next.isContinue {
                playLabel = DetailPresentation.continueLabel(episode: label, remaining: nil)
            } else {
                playLabel = String(localized: "Play \(label)")
            }
        } else {
            hasResume = false
        }
        if season == nil || !seasons.contains(season ?? -1) {
            season = next?.episode.season ?? seasons.first
        }
    }

    private func play(_ episode: Episode, fromStart: Bool = false) {
        guard !starting, presented == nil else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                let request = try await model.playbackRequest(kind: .series, providerID: episode.providerID,
                                                              seriesProviderID: seriesProviderID,
                                                              playlistID: playlistID, startFromBeginning: fromStart)
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
