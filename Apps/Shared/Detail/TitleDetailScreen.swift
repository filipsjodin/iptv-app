import Core
import Library
import SwiftUI

/// Detaljsidans gemensamma uppbyggnad för film och serie: backdrop med förhandsvisning överst, därunder logga eller
/// titel, betyg, år, genrer, åldersgräns, märken, beskrivning och medverkande; sedan knapparna (`actions`), eventuellt
/// avsnitt (`episodes`), "Skådespelare och team" och "Liknande titlar".
///
/// tvOS: backdropen fyller skärmen bakom innehållet, som rullar över den. iOS: backdropen är en 16:9-rad överst i
/// samma lodräta rullning.
///
/// Förhandsvisningen: skickas en kontroller ner (Hem) återanvänds den, och sidan tar bara över den (`focusChanged` är
/// en no-op när samma titel redan spelar). Annars skapar sidan en egen som den stoppar när den lämnas. Sidan stoppar
/// förhandsvisningen utan att vänta (fire-and-forget) när uppspelningen startar, och tar tillbaka den när spelaren
/// stängts. Sidan byggs bara för titlar som klarat åldersfiltret; kontrollern prövar det dessutom själv.
struct TitleDetailScreen<Actions: View, Episodes: View>: View {
    @Environment(AppModel.self) private var model
    let item: Library.LibraryItem
    let hero: HeroInfo
    let detail: TitleDetail?
    let similar: [Library.LibraryItem]
    let playlistID: UUID
    let sharedPreview: PreviewController?
    /// Spelaren visas över sidan.
    let playerActive: Bool
    private let actions: Actions
    private let episodes: Episodes

    @State private var scopedPreview: PreviewController?

    init(item: Library.LibraryItem, hero: HeroInfo, detail: TitleDetail?, similar: [Library.LibraryItem],
         playlistID: UUID, sharedPreview: PreviewController?, playerActive: Bool,
         @ViewBuilder actions: () -> Actions, @ViewBuilder episodes: () -> Episodes) {
        self.item = item
        self.hero = hero
        self.detail = detail
        self.similar = similar
        self.playlistID = playlistID
        self.sharedPreview = sharedPreview
        self.playerActive = playerActive
        self.actions = actions()
        self.episodes = episodes()
    }

    private var controller: PreviewController? { sharedPreview ?? scopedPreview }

    var body: some View {
        layout
            .onAppear {
                if sharedPreview == nil, scopedPreview == nil { scopedPreview = model.makePreviewController() }
                claimPreview()
            }
            .onDisappear {
                // En delad kontroller ägs av sidan som skapade den; bara en egen stoppas här.
                if sharedPreview == nil { stopPreview() }
            }
            .onChange(of: playerActive) { _, active in
                if active { stopPreview() } else { claimPreview() }
            }
    }

    private func claimPreview() {
        guard !playerActive else { return }
        controller?.focusChanged(to: item, playlistID: playlistID)
    }

    /// Stoppar utan att någon väntar på det.
    private func stopPreview() {
        let controller = controller
        Task { await controller?.stop() }
    }

    // MARK: Layout

    #if os(tvOS)
    private var layout: some View {
        ZStack {
            HeroBackdrop(hero: hero, preview: controller)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 32) {
                    Color.clear.containerRelativeFrame(.vertical) { height, _ in height * 0.4 }
                    sections
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 60)
            }
            .scrollClipDisabled()
        }
    }
    #else
    private var layout: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                backdropHeader
                VStack(alignment: .leading, spacing: 20) { sections }
                    .padding()
            }
        }
    }

    private var backdropHeader: some View {
        ZStack {
            Color.black
            ArtworkImage(url: HeroBackdrop.imageURL(for: hero), kind: hero.backdropURL == nil ? .poster : .backdrop,
                         placeholderSystemImage: "film")
            if let controller {
                PreviewSurface(controller: controller)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        .accessibilityHidden(true)
    }
    #endif

    @ViewBuilder
    private var sections: some View {
        TitleDetailInfo(hero: hero, detail: detail)
        DetailButtonRow { actions }
        episodes
        if let detail, !detail.cast.isEmpty || !detail.directors.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cast & Crew").font(.title3.bold())
                PeopleShelves(detail: detail, playlistID: playlistID)
            }
        }
        TitleShelf(title: String(localized: "Similar Titles"), items: similar, playlistID: playlistID,
                   preview: sharedPreview)
    }
}

/// Knapparna på en rad när de ryms, annars under varandra (smal skärm).
struct DetailButtonRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { content() }
            VStack(alignment: .leading, spacing: 12) { content() }
        }
    }
}

/// Uppgifterna under backdropen: logga (annars titeltext), betyg och åldersgräns, år, speltid, genrer,
/// kvalitetsmärken, beskrivning, medverkande i urval och regi. Det som saknas utelämnas (ingen tom yta).
struct TitleDetailInfo: View {
    let hero: HeroInfo
    let detail: TitleDetail?

    private var ratings: [TitleRating] {
        if let found = detail?.ratings, !found.isEmpty { return found }
        return hero.ratings
    }

    private var certification: String? { detail?.certification ?? hero.certification }
    private var year: Int? { detail?.year ?? hero.year }
    private var overview: String? { detail?.overview ?? hero.overview }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeroTitle(hero: hero)
            HStack(spacing: 20) {
                RatingsRow(ratings: ratings, certification: certification)
                if let year {
                    Text(verbatim: String(year))
                }
                if let minutes = hero.runtimeMinutes, minutes > 0 {
                    Text(verbatim: HeroInfoPanel.runtimeText(minutes: minutes))
                }
                QualityBadgeRow(badges: hero.badges)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let genres = detail?.genres, !genres.isEmpty {
                Text(verbatim: genres.joined(separator: " · ")).foregroundStyle(.secondary)
            }
            if let overview {
                Text(verbatim: overview)
                    .font(.callout)
                    .frame(maxWidth: 900, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                creditLine("Cast", detail.cast.prefix(4).map(\.name))
                creditLine("Director", detail.directors.prefix(3).map(\.name))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func creditLine(_ label: LocalizedStringKey, _ names: [String]) -> some View {
        if !names.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).bold()
                Text(verbatim: names.joined(separator: ", "))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
