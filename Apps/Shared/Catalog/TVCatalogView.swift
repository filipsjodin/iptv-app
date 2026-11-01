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
    @State private var menuState = CatalogMenuState()
    @FocusState private var menuFocus: String?
    /// Kortet som hade fokus när menyn öppnades; återställs om menyn stängs utan att en rad valts (eller raden saknas).
    @State private var focusBeforeMenu: CardID?
    /// Raden som ska få fokus så fort den laddats (menyn stängdes medan den laddades).
    @State private var pendingFocusSectionID: String?
    /// Beställd rullning till en rad; `serial` gör att samma rad kan väljas igen efter manuell rullning.
    @State private var scrollRequest: ScrollRequest?
    /// Fokusmålet efter stängning, väntar på att korten ska bli aktiverade igen (`applyCloseRequest`).
    @State private var closeRequest: CloseRequest?
    /// Väntar in en rad som laddas innan menyn stängs (`closeMenu`), respektive reservtilldelningen av fokus.
    @State private var closeWaitTask: Task<Void, Never>?
    @State private var closeFallbackTask: Task<Void, Never>?

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
    /// Antal 20 ms-avläsningar (ca 1 s) som menyn väntar på att en vald rad ska laddas innan den stängs ändå.
    private static let closeWaitPolls = 50

    private struct LoadKey: Equatable {
        let reloadKey: Date?
        let generation: Int
    }

    private struct ScrollRequest: Equatable {
        let sectionID: String
        let serial: Int
    }

    /// `sectionID` är `nil` eller okänd när menyn öppnades från Fortsätt titta.
    private struct CloseRequest: Equatable {
        let sectionID: String?
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
        .overlay(alignment: .leading) {
            if menuState.isOpen {
                CatalogCategoryMenu(entries: catalogModel.menuEntries, focusedEntry: $menuFocus,
                                    onSelect: selectMenuEntry)
                    .onMoveCommand { direction in
                        if direction == .right { closeMenu() }
                    }
                    // Fokus sätts först när menyn finns i vyn (inte i `openMenu`, som körs före den).
                    .defaultFocus($menuFocus, menuState.focusedEntryID)
                    .onAppear { menuFocus = menuState.focusedEntryID }
                    .transition(.move(edge: .leading))
            }
        }
        // Tillbaka stänger bara menyn medan den är öppen; annars ingen hanterare, så att Tillbaka beter sig som förut.
        .onExitCommand(perform: menuState.isOpen ? { closeMenu() } : nil)
        .onChange(of: pendingPhase) { _, phase in finishPendingFocus(phase) }
        // Sista menyposten valdes och raden blev tom: menyn har inget fokuserbart kvar och stängs utan fokusmål.
        .onChange(of: catalogModel.menuEntries.isEmpty) { _, empty in
            if empty, menuState.isOpen { resetMenu() }
        }
        // Korten är aktiverade igen först när `isOpen` blivit false i en renderad vy; då sätts fokus.
        .onChange(of: menuState.isOpen) { _, open in
            if !open { applyCloseRequest() }
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
            if !active {
                shutDown()
                resetMenu()
            }
        }
        .onChange(of: focused) { _, new in
            // Fokus hamnade på ett kort: en rad som laddas sent får inte ta det.
            if new != nil { pendingFocusSectionID = nil }
            handleFocus(new)
        }
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
        // Proxyn hoppar till raden som valts i sidomenyn (se `scrollRequest`).
        ScrollViewReader { proxy in
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
                            onSelect: { detail = DetailTarget(item: $0) },
                            onOpenMenu: openMenu
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
            // Neutral medan menyn är öppen, ett stängningsmål väntar eller en rad laddas för fokus, så att den inte slår ut
            // målet. `pendingFocusSectionID` löses alltid upp (rad klar, fel/tom, borttagen, flikbyte) och släpper den.
            .defaultFocus($focused, (menuState.isOpen || closeRequest != nil || pendingFocusSectionID != nil) ? nil : firstCardID,
                          priority: .userInitiated)
            // Korten bakom menyn får inte ta fokus medan den är öppen.
            .disabled(menuState.isOpen)
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                withAnimation { proxy.scrollTo(request.sectionID, anchor: .top) }
            }
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
                            .onMoveCommand(perform: item.id == continueItems.first?.id ? { direction in
                                if direction == .left { openMenu(from: Self.continueID) }
                            } : nil)
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
        // Menyn är öppen: fokus lämnade korten för menyn. Heron lämnas som den är och förhandsvisningen tystas.
        if menuState.isOpen {
            previewController?.focusChanged(to: nil, playlistID: playlistID)
            return
        }
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

    // MARK: Sidomeny

    /// Fasen för raden som väntar på fokus efter att menyn stängts; `nil` när ingen väntar.
    private var pendingPhase: CatalogSection.Phase? {
        pendingFocusSectionID.flatMap { catalogModel.section(id: $0)?.phase }
    }

    /// Öppnas av vänster på första kortet i en rad. Gör inget om det inte finns några menyposter.
    private func openMenu(from sectionID: String) {
        guard !menuState.isOpen else { return }
        let saved = focused
        withAnimation { menuState.open(from: sectionID, entries: catalogModel.menuEntries) }
        guard menuState.isOpen else { return }
        focusBeforeMenu = saved
        pendingFocusSectionID = nil
        // Ingen förhandsvisning medan menyn är öppen; heron lämnas som den är.
        previewController?.focusChanged(to: nil, playlistID: playlistID)
        closeRequest = nil
        closeFallbackTask?.cancel()
        // Menyns fokus sätts av menyns egen `onAppear`/`defaultFocus`; det här är bara en reserv.
        let entry = menuState.focusedEntryID
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            if menuState.isOpen, menuFocus == nil { menuFocus = entry }
        }
    }

    /// Ett val i menyn: rulla till raden och starta dess laddning. Menyn och fokus i den ligger kvar.
    private func selectMenuEntry(_ id: String) {
        menuState.select(id)
        scrollRequest = ScrollRequest(sectionID: id, serial: (scrollRequest?.serial ?? 0) + 1)
        loadSection(id)
    }

    /// Startar laddningen av raden (en no-op om den redan är laddad eller laddas).
    private func loadSection(_ id: String) {
        let model = model, playlistID = playlistID, kind = kind, catalogModel = catalogModel
        Task {
            await catalogModel.load(sectionID: id) { categoryID, limit in
                try await model.catalogItems(playlistID: playlistID, kind: kind, categoryID: categoryID, limit: limit)
            }
        }
    }

    /// Stänger menyn. Är den senast valda raden inte laddad ännu väntas den in först (högst `closeWaitPolls` avläsningar à 20 ms), med
    /// menyn kvar öppen och fokus i den, så att första kortet finns när fokus sätts. Ett andra tryck under väntan
    /// startar ingen ny väntan.
    private func closeMenu() {
        guard menuState.isOpen, closeWaitTask == nil else { return }
        if let id = menuState.selectedSectionID, isAwaitingLoad(id) {
            closeWaitTask = Task {
                if catalogModel.section(id: id)?.phase == .unloaded { loadSection(id) }
                for _ in 0..<Self.closeWaitPolls {
                    try? await Task.sleep(for: .milliseconds(20))
                    if Task.isCancelled { return }
                    // Valet kan ha ändrats under väntan; den senast valda raden räknas.
                    if let current = menuState.selectedSectionID, current == id, catalogModel.section(id: id)?.phase == .loading {
                        continue
                    }
                    break
                }
                guard !Task.isCancelled else { return }
                closeWaitTask = nil
                finishClose()
            }
            return
        }
        finishClose()
    }

    private func isAwaitingLoad(_ id: String) -> Bool {
        switch catalogModel.section(id: id)?.phase {
        case .loading, .unloaded: true
        default: false
        }
    }

    private func finishClose() {
        guard menuState.isOpen else { return }
        let target = withAnimation { menuState.close() }
        menuFocus = nil
        // Målet sparas; `onChange(of: menuState.isOpen)` tillämpar det när korten är aktiverade igen.
        closeRequest = CloseRequest(sectionID: target)
    }

    private func applyCloseRequest() {
        guard let request = closeRequest else { return }
        closeRequest = nil
        moveFocus(for: request)
        // Reserv: ignorerades tilldelningen (vyn inte klar) görs den om en kort stund, om inget annat tagit fokus.
        closeFallbackTask?.cancel()
        closeFallbackTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, !menuState.isOpen, focused == nil, pendingFocusSectionID == nil else { return }
            moveFocus(for: request)
        }
    }

    private func moveFocus(for request: CloseRequest) {
        if let id = request.sectionID, catalogModel.section(id: id) != nil {
            focusFirstCard(inSection: id)
        } else {
            restoreFocus()
        }
    }

    /// Flikbyte: menyn stängs utan att något fokusmål tillämpas.
    private func resetMenu() {
        closeWaitTask?.cancel()
        closeWaitTask = nil
        closeFallbackTask?.cancel()
        closeFallbackTask = nil
        if menuState.isOpen { _ = menuState.close() }
        menuFocus = nil
        closeRequest = nil
        pendingFocusSectionID = nil
    }

    private func focusFirstCard(inSection id: String) {
        if let item = catalogModel.firstItemID(inSection: id) {
            focused = CardID(sectionID: id, itemID: item)
            return
        }
        switch catalogModel.section(id: id)?.phase {
        case .loading:
            // Raden laddas: fokus sätts av `finishPendingFocus` när den är klar.
            pendingFocusSectionID = id
        default:
            restoreFocus()
        }
    }

    private func finishPendingFocus(_ phase: CatalogSection.Phase?) {
        guard let id = pendingFocusSectionID else { return }
        // Raden försvann (ny konfiguration): ingen väntan längre.
        guard let phase else { restoreFocus(); return }
        guard phase != .loading else { return }
        pendingFocusSectionID = nil
        focusFirstCard(inSection: id)
    }

    /// Fokus tillbaka till kortet som hade det före menyn, annars sidans standardfokus.
    private func restoreFocus() {
        pendingFocusSectionID = nil
        focused = focusBeforeMenu ?? firstCardID
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
    /// Vänster på radens första kort öppnar sidomenyn med radens id.
    let onOpenMenu: (String) -> Void

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
                            // Känd risk: `onMoveCommand` kanske inte utlöses på första kortet när fokus inte kan flytta
                            // sig åt vänster. Möjlig reserv (inte byggd): en osynlig fokuserbar vy (opacity 0.01,
                            // bredd 1) först i raden som öppnar menyn när den får fokus.
                            .onMoveCommand(perform: item.id == items.first?.id ? { direction in
                                if direction == .left { onOpenMenu(section.id) }
                            } : nil)
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
