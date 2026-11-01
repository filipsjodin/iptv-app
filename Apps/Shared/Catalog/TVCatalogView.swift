#if os(tvOS)
import Core
import Discovery
import Library
import SwiftUI

/// Fokusnyckel för ett kort på sidan: sektionen (`CatalogSection.id`, eller `TVCatalogView.continueID`) och titeln
/// (eller `showAllItemID` för kortet "Show All").
private struct CardID: Hashable {
    let sectionID: String
    let itemID: String
}

/// Filmer- och Serier-flikarna på tvOS som en sida: som Hem, men utan helskärmsheron. Backdrop och uppgifter om den
/// fokuserade titeln ligger på fasta platser (uppgifterna i övre delen), och raderna, en per kategori, i de nedre
/// `rowsFraction` av höjden. Raderna laddas först när de kommer i bild (`CatalogBrowseModel.load`).
///
/// Fokus på ett kort laddar heron (`HeroModel.focus`) och startar förhandsvisningen (`PreviewController.focusChanged`,
/// som själv väntar ut 1,5 s). Fokus på "Show All" nollställer förhandsvisningen. Hero läses bara i de små vyerna
/// `CatalogBackdropLayer` och `CatalogInfoLayer`, så att snabba fokusbyten inte ritar om korten.
struct TVCatalogView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    let kind: ContentKind
    let reloadKey: Date?
    let tabActive: Bool

    @State private var catalogModel = CatalogBrowseModel()
    @State private var continueItems: [ContinueWatchingItem] = []
    @State private var loading = true
    @State private var failed = false
    @State private var presented: PlayerPresentation?
    /// Ökas när vyn visas igen eller spelaren stängs, så att "Fortsätt titta" läses om.
    @State private var generation = 0
    /// Ökas varje gång sektionerna konfigurerats om; raderna laddar om sig själva när den ändras.
    @State private var epoch = 0
    @State private var heroModel = HeroModel()
    /// Hålls av vyn så att den lever precis lika länge som sidan (kontrollern har också ett säkerhetsnät i deinit).
    @State private var previewController: PreviewController?
    @State private var detail: DetailTarget?
    @FocusState private var focused: CardID?

    /// Id för raden "Fortsätt titta", som inte ingår i `CatalogBrowseModel`.
    fileprivate static let continueID = "continue"
    fileprivate static let showAllItemID = "showAll"
    /// Radytans andel av skärmhöjden (resten överst går till uppgifterna om den fokuserade titeln).
    private static let rowsFraction: CGFloat = 0.58
    /// Övertoningen längst upp i radytan: rader som rullat förbi tonas ut mot den.
    private static let rowsFadeHeight: CGFloat = 40
    /// Utrymmet ovanför kortet i fokus: övertoningen plus radens rubrik.
    private static let rowsTopMargin: CGFloat = rowsFadeHeight + 130
    /// Extra avstånd mellan uppgifterna om titeln och radytan.
    private static let infoGap: CGFloat = 40

    private struct LoadKey: Equatable {
        let reloadKey: Date?
        let generation: Int
    }

    private struct DetailTarget: Hashable {
        let item: Library.LibraryItem
        var kind: ContentKind { item.kind }
        var providerID: String { item.providerID }
    }

    /// Första kortet på sidan: "Fortsätt titta", annars första titeln i första raden med innehåll. Är en rad före
    /// ännu inte laddad väntar vi på den (så att fokus inte hoppar till en rad längre ner).
    private var firstCardID: CardID? {
        if let first = continueItems.first { return CardID(sectionID: Self.continueID, itemID: first.id) }
        for section in catalogModel.sections {
            guard case let .loaded(items, _) = section.phase else { return nil }
            if let first = items.first { return CardID(sectionID: section.id, itemID: first.id) }
        }
        return nil
    }

    private var hasContent: Bool {
        !continueItems.isEmpty || !catalogModel.menuEntries.isEmpty
    }

    // MARK: Sidan

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CatalogBackdropLayer(heroModel: heroModel, preview: previewController)
            VStack(spacing: 0) {
                CatalogInfoLayer(heroModel: heroModel)
                    .padding(.horizontal, 80)
                    .padding(.bottom, Self.infoGap)
                    .frame(maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                rowsArea
                    .containerRelativeFrame(.vertical) { height, _ in height * Self.rowsFraction }
            }
        }
        .task(id: LoadKey(reloadKey: reloadKey, generation: generation)) { await loadContinue() }
        .task(id: reloadKey) { await loadListing() }
        .onAppear {
            generation += 1
            heroModel.attach(model)
            if previewController == nil { previewController = model.makePreviewController() }
            // Tillbaka från en detaljsida: sidan tar över förhandsvisningen igen (samma titel är en no-op).
            refocus()
        }
        .onDisappear {
            // En detaljsida öppnas ovanpå sidan och tar över förhandsvisningen; den stoppar den själv.
            if detail == nil { shutDown() }
        }
        // Flikbyte med en detaljsida öppen: `onDisappear` körs inte då, så förhandsvisningen stoppas här.
        .onChange(of: tabActive) { _, active in
            if !active { shutDown() }
        }
        .onChange(of: focused) { _, new in handleFocus(new) }
        .onChange(of: presented?.id) { _, id in
            if id != nil { shutDown() }
        }
        .playerCover($presented, playlistID: playlistID, onDismiss: {
            generation += 1
            refocus()
        })
        .navigationDestination(item: $detail) { target in
            // Detaljsidan tar över förhandsvisningen (samma kontroller, ingen omstart för samma titel).
            TitleDestination(kind: target.kind, providerID: target.providerID, playlistID: playlistID,
                             preview: previewController, item: target.item)
        }
    }

    // MARK: Rader

    @ViewBuilder
    private var rowsArea: some View {
        // `menuEntries` döljer bara rader som är laddade och tomma: är den tom finns inga olästa rader som väntar.
        if !hasContent {
            Group {
                if loading {
                    ProgressView()
                } else if failed {
                    Text("The library could not be read.")
                } else {
                    Text("Nothing here yet.")
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            rowsList
        }
    }

    private var rowsList: some View {
        // Proxyn används av sidomenyn (Task 5) för att hoppa till en rad.
        ScrollViewReader { _ in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !continueItems.isEmpty {
                        continueSection
                            .id(Self.continueID)
                    }
                    ForEach(catalogModel.sections) { section in
                        CatalogSectionView(
                            sectionID: section.id, playlistID: playlistID, kind: kind, reloadKey: reloadKey,
                            epoch: epoch, catalogModel: catalogModel, focused: $focused,
                            onSelect: { detail = DetailTarget(item: $0) }
                        )
                        .id(section.id)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 60)
            }
            .scrollClipDisabled()
            // Utrymme för övertoningen överst: raden i fokus hamnar under den, inte i den.
            .contentMargins(.top, Self.rowsTopMargin, for: .scrollContent)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.rowsFadeHeight)
                    Rectangle()
                }
            }
            .focusSection()
            .defaultFocus($focused, firstCardID, priority: .userInitiated)
        }
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue Watching").font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 24) {
                    ForEach(continueItems) { item in
                        Button { playContinue(item) } label: { ContinueWatchingCard(item: item) }
                            .buttonStyle(.card)
                            .focused($focused, equals: CardID(sectionID: Self.continueID, itemID: item.id))
                    }
                }
                .padding(.vertical, TitleShelf.focusPadding)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    // MARK: Fokus

    private func handleFocus(_ id: CardID?) {
        // En detaljsida är öppen: fokus lämnade korten för att sidan öppnades. Sidan äger förhandsvisningen nu; ett
        // nil-fokus här får varken stoppa den eller nollställa heron.
        if id == nil, detail != nil { return }
        guard let id, let found = locate(id) else {
            // Show All, eller inget kort: förhandsvisningen tystas och heron ersätter ingen pågående laddning.
            heroModel.focus(nil, playlistID: playlistID)
            previewController?.focusChanged(to: nil, playlistID: playlistID)
            return
        }
        heroModel.focus(found.item, playlistID: playlistID)
        previewController?.focusChanged(to: found.item, playlistID: playlistID)
        // Fortsätt titta har inga affischer att förhämta (som i Hem).
        if let row = found.row {
            heroModel.prefetchWindow(rows: prefetchRows, focusedRow: row, focusedIndex: found.index,
                                     playlistID: playlistID)
        }
    }

    /// Sektionerna som `HomeRow`, i samma ordning som de visas, för `HeroModel.prefetchWindow` (som bara läser
    /// `titles`). `RowID.genre(index, kind)` är en platshållare: id:t används inte av förhämtningen, men måste vara
    /// unikt per rad. Olästa, laddande och tomma rader får inga titlar.
    private var prefetchRows: [HomeRow] {
        catalogModel.sections.enumerated().map { index, section in
            var titles: [Library.LibraryItem] = []
            if case let .loaded(items, _) = section.phase { titles = items }
            return HomeRow(id: .genre(index, kind), title: section.title, titles: titles)
        }
    }

    /// Titeln bakom ett fokuserat kort, sektionens index i `catalogModel.sections` (`nil` för Fortsätt titta) och
    /// titelns index i raden; `nil` för "Show All" och okända kort.
    private func locate(_ id: CardID) -> (item: Library.LibraryItem, row: Int?, index: Int)? {
        if id.sectionID == Self.continueID {
            guard let index = continueItems.firstIndex(where: { $0.id == id.itemID }) else { return nil }
            return (continueItems[index].libraryItem, nil, index)
        }
        guard let row = catalogModel.sections.firstIndex(where: { $0.id == id.sectionID }),
              case let .loaded(items, _) = catalogModel.sections[row].phase,
              let index = items.firstIndex(where: { $0.id == id.itemID }) else { return nil }
        return (items[index], row, index)
    }

    /// Kör om fokushanteringen för det fokuserade kortet (efter att sidan visats igen eller spelaren stängts, då
    /// förhandsvisning och hero har släppts men fokus kan ligga kvar).
    private func refocus() {
        if let focused { handleFocus(focused) }
    }

    /// Sidan lämnas eller spelaren öppnas: förhandsvisningen stoppas synkront, och hero och förhämtning släpps.
    private func shutDown() {
        previewController?.stopNow()
        heroModel.reset()
    }

    // MARK: Uppspelning

    private func playContinue(_ item: ContinueWatchingItem) {
        guard presented == nil else { return }
        presented = PlayerPresentation(request: item.request,
                                       nextEpisodeProvider: model.nextEpisodeProvider(for: item.request))
    }

    // MARK: Laddning

    private func loadContinue() async {
        let items = await model.continueWatching(playlistID: playlistID, kind: kind)
        guard !Task.isCancelled else { return }
        continueItems = items
    }

    private func loadListing() async {
        do {
            let listing = try await model.catalogListing(playlistID: playlistID, kind: kind)
            // En ersatt laddning (ny nyckel) får inte skriva över en nyare.
            guard !Task.isCancelled else { return }
            catalogModel.configure(listing)
            epoch += 1
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
        loading = false
    }
}

// MARK: - Hero-lager

/// Backdropen (och förhandsvisningen). Läser `heroModel.current` här och inte i sidans `body`.
private struct CatalogBackdropLayer: View {
    let heroModel: HeroModel
    let preview: PreviewController?

    var body: some View {
        HeroBackdrop(hero: heroModel.current, preview: preview)
    }
}

/// Uppgifterna om den fokuserade titeln, i sidans övre del.
private struct CatalogInfoLayer: View {
    let heroModel: HeroModel

    var body: some View {
        if let hero = heroModel.current {
            HeroInfoPanel(hero: hero)
        } else {
            Color.clear
        }
    }
}

// MARK: - Rad

/// En kategorirad: rubrik och kort. Laddas när raden kommer i bild; en rad som blir tom döljs.
private struct CatalogSectionView: View {
    @Environment(AppModel.self) private var model
    let sectionID: String
    let playlistID: UUID
    let kind: ContentKind
    let reloadKey: Date?
    let epoch: Int
    let catalogModel: CatalogBrowseModel
    let focused: FocusState<CardID?>.Binding
    let onSelect: (Library.LibraryItem) -> Void

    /// Höjden på en kortrad (affisch, titel och fokusmarginal), så att platshållaren inte får sidan att hoppa.
    private static let rowHeight: CGFloat = PosterCard.defaultWidth * 1.5 + 6 + 40 + 2 * TitleShelf.focusPadding

    var body: some View {
        if let section = catalogModel.section(id: sectionID), !isEmptyLoaded(section) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: section.title).font(.headline)
                content(section)
            }
            .task(id: epoch) { await load() }
        }
    }

    private func isEmptyLoaded(_ section: CatalogSection) -> Bool {
        if case let .loaded(items, _) = section.phase { return items.isEmpty }
        return false
    }

    @ViewBuilder
    private func content(_ section: CatalogSection) -> some View {
        if case let .loaded(items, hasMore) = section.phase {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 24) {
                    ForEach(items) { item in
                        Button { onSelect(item) } label: { PosterCard(item: item, playlistID: playlistID) }
                            .buttonStyle(.card)
                            .focused(focused, equals: CardID(sectionID: section.id, itemID: item.id))
                    }
                    if hasMore, let categoryID = section.categoryID {
                        showAll(section, categoryID: categoryID)
                    }
                }
                .padding(.vertical, TitleShelf.focusPadding)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        } else {
            Color.clear.frame(height: Self.rowHeight)
        }
    }

    private func showAll(_ section: CatalogSection, categoryID: String) -> some View {
        NavigationLink {
            ItemListView(playlistID: playlistID, kind: kind, categoryID: categoryID,
                         title: Text(verbatim: section.title), reloadKey: reloadKey)
        } label: {
            Label("Show All", systemImage: "chevron.right.circle")
                .frame(width: PosterCard.defaultWidth, height: PosterCard.defaultWidth * 1.5)
        }
        .buttonStyle(.card)
        .focused(focused, equals: CardID(sectionID: section.id, itemID: TVCatalogView.showAllItemID))
    }

    private func load() async {
        let model = model, playlistID = playlistID, kind = kind
        await catalogModel.load(sectionID: sectionID) { categoryID, limit in
            try await model.catalogItems(playlistID: playlistID, kind: kind, categoryID: categoryID, limit: limit)
        }
    }
}

private extension ContinueWatchingItem {
    /// Serien (för ett avsnitt) eller filmen som posten hör till, för hero och förhandsvisning.
    var libraryItem: Library.LibraryItem {
        let key = request.key
        if let series = key.seriesProviderID {
            return Library.LibraryItem(kind: .series, providerID: series, title: title, year: nil, posterURL: posterURL)
        }
        return Library.LibraryItem(kind: key.kind, providerID: key.providerID, title: title, year: nil,
                                   posterURL: posterURL)
    }
}
#endif
