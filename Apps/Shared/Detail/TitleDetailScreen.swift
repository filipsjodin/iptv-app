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
/// stängts.
///
/// Ägarregel (en ägare åt gången): en delad kontroller når varje sida som kan nås från en detaljsida (personlistor och
/// liknande titlar får den vidare), och den sida som senast visades äger förhandsvisningen. Ägarbyte sker bara när en
/// sida visas (`focusChanged`: samma titel är en no-op, en annan titel ersätter den förra direkt), aldrig när en sida
/// lämnas; då vore resultatet beroende av i vilken ordning SwiftUI anropar `onDisappear` och `onAppear`. En sida utan
/// förhandsvisning (personlistan) tystar kontrollern när den visas. Laddningsläget (`holdsSharedPreview`) hävdar den kända titeln, så Hem → detalj är ingen omstart; nekad, misslyckad eller saknad titel tystar. Lämnas hela presentationen utan att en annan sida tar över (flikbyte i bibliotekets `TabView`) stoppar Hem (ägaren) kontrollern via `homeTabActive`; detaljsidan stoppar inte en delad kontroller när den lämnas, så vanliga push/pop (detalj → person → titel) påverkas inte, och tillbaka på fliken hävdar sidan förhandsvisningen igen i `onAppear`. Sidan byggs bara för titlar som klarat åldersfiltret; kontrollern prövar det dessutom själv.
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
    #if !os(tvOS)
    /// Användaren har tryckt på "Show Preview" och förhandsvisningen har inte avslutats än.
    @State private var previewRequested = false
    #endif

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
                #if os(tvOS)
                // En delad kontroller ägs av sidan som skapade den; bara en egen stoppas här.
                if sharedPreview == nil { stopPreview() }
                #else
                // iPhone/iPad: ingen förhandsvisning överlever sidan, så att anslutningen aldrig hålls. Ingen annan
                // sida startar något av sig själv, så att stoppa även en delad kontroller krockar inte med ägarregeln.
                stopUserPreview()
                #endif
            }
            .onChange(of: playerActive) { _, active in
                if active { stopPreview() } else { claimPreview() }
            }
    }

    private func claimPreview() {
        guard !playerActive else { return }
        DetailPreviewGate.claimOnAppear(controller, item: item, playlistID: playlistID)
    }

    /// Stoppar utan att någon väntar på det.
    private func stopPreview() {
        #if !os(tvOS)
        // Stoppet (t.ex. när spelaren startar) lämnar kontrollern idle utan att `.artwork` passeras: knappen återställs.
        previewRequested = false
        #endif
        let controller = controller
        Task { await controller?.stop() }
    }

    #if !os(tvOS)
    /// Stoppar den användarstartade förhandsvisningen direkt (synkront) och återställer knappen.
    private func stopUserPreview() {
        previewRequested = false
        controller?.stopNow()
    }

    private func startUserPreview() {
        previewRequested = DetailPreviewGate.userStart(controller, item: item, playlistID: playlistID,
                                                       previewsEnabled: model.settings.previewsEnabled,
                                                       kids: model.kidsRestricted)
    }

    private var showsPreviewButton: Bool {
        !playerActive && DetailPreviewGate.showsPreviewButton(previewsEnabled: model.settings.previewsEnabled,
                                                              kids: model.kidsRestricted)
    }
    #endif

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
        .overlay(alignment: .bottomTrailing) { previewButton }
        // Rullas artworken bort stoppas förhandsvisningen direkt, så att anslutningen inte hålls i onödan.
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            if !visible { stopUserPreview() }
        }
        .onChange(of: controller?.state) { _, state in
            // Föll förhandsvisningen tillbaka till artwork (tidsgräns, upptagen anslutning) är knappen åter "Show".
            if case .artwork? = state { previewRequested = false }
        }
    }

    @ViewBuilder
    private var previewButton: some View {
        if showsPreviewButton {
            Button {
                if previewRequested { stopUserPreview() } else { startUserPreview() }
            } label: {
                if previewRequested {
                    Label("Stop Preview", systemImage: "stop.fill")
                } else {
                    Label("Show Preview", systemImage: "play.rectangle.fill")
                }
            }
            .font(.callout)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.white)
            .padding(12)
        }
    }
    #endif

    @ViewBuilder
    private var sections: some View {
        TitleDetailInfo(hero: hero, detail: detail)
        DetailButtonRow { actions }
        episodes
        // Barnprofil: ingen ruta (rutan läser dessutom ingenting där).
        if !model.kidsRestricted, item.kind == .movie || item.kind == .series {
            TitleInfoBox(kind: item.kind, providerID: item.providerID, playlistID: playlistID,
                         playerActive: playerActive)
        }
        if let detail, !detail.cast.isEmpty || !detail.directors.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cast & Crew").font(.title3.bold())
                PeopleShelves(detail: detail, playlistID: playlistID, preview: sharedPreview)
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

extension View {
    /// Sidor utan innehåll (laddar, nekad, misslyckad, titeln finns inte) äger ingen förhandsvisning men ligger
    /// ovanpå föregående sidas: den delade kontrollern tystas och stoppas när en sådan gren visas.
    func stopsSharedPreview(_ preview: PreviewController?, playlistID: UUID) -> some View {
        onAppear { preview?.focusChanged(to: nil, playlistID: playlistID) }
    }

    /// Laddningsläget: den kända titeln behåller förhandsvisningen (samma titel är en no-op, så ingen omstart när
    /// den redan spelar eller startar); utan känd titel stoppas den.
    func holdsSharedPreview(_ preview: PreviewController?, item: Library.LibraryItem?, playlistID: UUID) -> some View {
        // iPhone/iPad: ingen autostart, så den kända titeln hävdas inte (en eventuell förhandsvisning stoppas).
        onAppear { DetailPreviewGate.claimOnAppear(preview, item: item, playlistID: playlistID) }
    }
}
