#if os(tvOS)
import Core
import Discovery
import Library
import os
import SwiftUI

/// Hem på tvOS i två lägen, i en och samma lodräta sida:
///
/// - **Helskärmshero** (första skärmen): backdrop, logga, uppgifter och knapparna Spela och Mer info för en rekommenderad
///   titel, och "Scrolla ner för att se mer". Titeln byts var `featuredInterval` bland de första titlarna i För dig
///   (`FeaturedPicker.picks`) så länge fokus ligger här. Ingen förhandsvisning spelas.
/// - **Bläddring** (när ett kort har fokus): uppgifterna om den fokuserade titeln (`HeroInfoPanel`, utan knappar) i
///   övre halvan och raderna nedanför. Upp från första raden går tillbaka till helskärmsheron.
///
/// Fokus på ett kort laddar heron (`HeroModel.focus`), startar förhandsvisningen (`PreviewController.focusChanged`,
/// som själv väntar ut 1,5 s) och flyttar förhämtningsfönstret. Tappar korten fokus (upp till helskärmsheron eller
/// toppmenyn) stoppas förhandsvisningen och heron återgår till den rekommenderade titeln.
///
/// Ett kort och Mer info öppnar titelns detaljsida (`TitleDestination`) och skickar med förhandsvisningen, som sidan
/// tar över. Spela startar filmen, eller för en serie avsnittet detaljsidans huvudknapp skulle spela
/// (`AppModel.featuredPlaybackRequest`: samma väg, barnfilter och återupptagning).
struct TVHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.homeTabActive) private var tabActive
    let playlistID: UUID
    let reloadKey: Date?

    @State private var rows: [HomeRow] = []
    @State private var loading = true
    @State private var failed = false
    @State private var presented: PlayerPresentation?
    /// Ökas när vyn visas igen eller spelaren stängs, så att raderna läses om.
    @State private var generation = 0
    @State private var heroModel = HeroModel()
    /// Hålls av vyn så att den lever precis lika länge som Hem (kontrollern har också ett säkerhetsnät i deinit).
    @State private var previewController: PreviewController?
    @State private var detail: DetailTarget?
    /// De rekommenderade titlarna i helskärmsheron och vilken som visas just nu.
    @State private var featuredPicks: [Library.LibraryItem] = []
    @State private var featuredIndex = 0
    @State private var starting = false
    /// Spela-knappens start (en långsam `playbackRequest`); avbryts när Hem försvinner.
    @State private var startTask: Task<Void, Never>?
    @FocusState private var focused: CardID?
    @FocusState private var featuredFocus: FeaturedButton?

    /// Hur många titlar helskärmsheron växlar mellan, och hur länge varje visas.
    private static let featuredCount = 5
    private static let featuredInterval: Duration = .seconds(8)
    private static let featuredID = "featured"

    private enum FeaturedButton: Hashable {
        case play, info
    }

    private struct RotationKey: Equatable {
        let active: Bool
        let count: Int
    }

    private struct LoadKey: Equatable {
        let reloadKey: Date?
        let generation: Int
    }

    private struct CardID: Hashable {
        let row: RowID
        let itemID: String
    }

    private struct DetailTarget: Hashable {
        let item: Library.LibraryItem
        var kind: ContentKind { item.kind }
        var providerID: String { item.providerID }
    }

    private static let signposter = OSSignposter(subsystem: "se.sjodin.iptv", category: "home")

    /// Ett kort har fokus: bläddringsläget (annars helskärmsheron).
    private var browsing: Bool { focused != nil }

    private var currentPick: Library.LibraryItem? {
        featuredPicks.indices.contains(featuredIndex) ? featuredPicks[featuredIndex] : nil
    }

    /// Titeln i helskärmsheron byts bara när inget annat har fokus och ingen annan sida eller spelare är öppen.
    private var rotationActive: Bool { focused == nil && detail == nil && presented == nil && tabActive }

    var body: some View {
        ZStack {
            HeroBackdrop(hero: heroModel.current, preview: previewController)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        featuredSection
                            .containerRelativeFrame(.vertical)
                            .id(Self.featuredID)
                        rowsContent
                            .padding(.horizontal, 80)
                            .padding(.bottom, 60)
                    }
                }
                .scrollClipDisabled()
                .defaultFocus($featuredFocus, .play)
                // Tillbaka upp från raderna: sidan rullas så att hela helskärmsheron syns.
                .onChange(of: featuredFocus) { _, new in
                    if new != nil { withAnimation { proxy.scrollTo(Self.featuredID, anchor: .top) } }
                }
            }
            if browsing, let hero = heroModel.current {
                VStack(spacing: 0) {
                    HeroInfoPanel(hero: hero)
                        .frame(maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.horizontal, 80)
                    Color.clear.containerRelativeFrame(.vertical) { height, _ in height * 0.5 }
                }
                .allowsHitTesting(false)
            }
        }
        .task(id: RotationKey(active: rotationActive, count: featuredPicks.count)) { await rotateFeatured() }
        .task(id: LoadKey(reloadKey: reloadKey, generation: generation)) { await load() }
        .onAppear {
            generation += 1
            heroModel.attach(model)
            if previewController == nil { previewController = model.makePreviewController() }
            // Tillbaka från en detaljsida: Hem tar över förhandsvisningen igen (samma titel är en no-op), eller
            // tystar den när inget kort har fokus.
            if focused == nil { previewController?.focusChanged(to: nil, playlistID: playlistID) }
            refocus()
        }
        .onDisappear {
            // En detaljsida öppnas ovanpå Hem och tar över förhandsvisningen; den stoppar den själv när den behöver.
            if detail == nil { shutDown() }
        }
        // Flikbyte med en detaljsida öppen: Hems `onDisappear` körs inte då, så förhandsvisningen stoppas här. Tillbaka
        // på fliken tar detaljsidan (`onAppear`) över den igen.
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

    // MARK: Helskärmshero

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 0)
            if let pick = currentPick {
                featuredInfo(pick)
                HStack(spacing: 20) {
                    Button { playFeatured(pick) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(starting)
                    .focused($featuredFocus, equals: .play)
                    Button { detail = DetailTarget(item: pick) } label: {
                        Label("More Info", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)
                    .focused($featuredFocus, equals: .info)
                }
                Label("Scroll down to see more", systemImage: "chevron.compact.down")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Group {
                    if failed {
                        Text("The library could not be read.")
                    } else {
                        Text("Nothing here yet.")
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        // Knapparna ligger kvar (osynliga) i bläddringsläget: upp från första raden når Spela.
        .opacity(browsing ? 0 : 1)
    }

    /// Uppgifterna om den rekommenderade titeln: heron när den hör till titeln, annars bara titeln (den läses in).
    @ViewBuilder
    private func featuredInfo(_ pick: Library.LibraryItem) -> some View {
        if let hero = heroModel.current, hero.kind == pick.kind, hero.providerID == pick.providerID {
            HeroInfoPanel(hero: hero)
        } else {
            Text(verbatim: pick.title).font(.largeTitle.bold()).lineLimit(2)
        }
    }

    /// Helskärmsheron visar rekommenderad titel igen: förhandsvisningen tystas och heron byts till titeln.
    private func showFeatured() {
        previewController?.focusChanged(to: nil, playlistID: playlistID)
        heroModel.focus(currentPick, playlistID: playlistID)
    }

    /// Byter rekommenderad titel med jämna mellanrum tills fokus eller en annan sida tar över (då avbryts uppgiften).
    private func rotateFeatured() async {
        guard rotationActive, featuredPicks.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.featuredInterval)
            guard !Task.isCancelled, rotationActive, !featuredPicks.isEmpty else { return }
            featuredIndex = (featuredIndex + 1) % featuredPicks.count
            heroModel.focus(currentPick, playlistID: playlistID)
        }
    }

    private func playFeatured(_ item: Library.LibraryItem) {
        guard !starting, presented == nil else { return }
        starting = true
        startTask = Task {
            defer { starting = false }
            do {
                let request = try await model.featuredPlaybackRequest(for: item, playlistID: playlistID)
                // Hem kan ha försvunnit under den långsamma förfrågan: öppna då ingen spelare.
                guard !Task.isCancelled else { return }
                presented = PlayerPresentation(request: request,
                                               nextEpisodeProvider: model.nextEpisodeProvider(for: request))
            } catch is CancellationError {
                return
            } catch {
                model.lastError = UserFacingError.message(for: error)
            }
        }
    }

    // MARK: Rader

    private var rowsContent: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(rows) { row in shelf(row) }
        }
    }

    @ViewBuilder
    private func shelf(_ row: HomeRow) -> some View {
        if row.id == .continueWatching ? !row.continueItems.isEmpty : !row.titles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: row.title).font(.headline)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 24) {
                        cards(row)
                    }
                    .padding(.vertical, TitleShelf.focusPadding)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    @ViewBuilder
    private func cards(_ row: HomeRow) -> some View {
        if row.id == .continueWatching {
            ForEach(row.continueItems) { item in
                Button { playContinue(item) } label: { ContinueWatchingCard(item: item) }
                    .buttonStyle(.card)
                    .focused($focused, equals: CardID(row: row.id, itemID: item.id))
            }
        } else if case .topTen = row.id {
            // Stora siffror 1-10 bredvid affischen; bara systemtypografi.
            ForEach(Array(row.titles.prefix(10).enumerated()), id: \.element.id) { rank, item in
                HStack(alignment: .bottom, spacing: 8) {
                    Text(verbatim: String(rank + 1))
                        .font(.system(size: 120, weight: .bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    card(item, in: row)
                }
            }
        } else {
            ForEach(row.titles) { item in card(item, in: row) }
        }
    }

    private func card(_ item: Library.LibraryItem, in row: HomeRow) -> some View {
        Button {
            detail = DetailTarget(item: item)
        } label: {
            PosterCard(item: item, playlistID: playlistID)
        }
        .buttonStyle(.card)
        .focused($focused, equals: CardID(row: row.id, itemID: item.id))
    }

    // MARK: Fokus

    private func handleFocus(_ id: CardID?) {
        // En detaljsida är öppen: fokus lämnade korten för att sidan öppnades. Sidan äger förhandsvisningen nu; ett
        // nil-fokus här får varken stoppa den eller nollställa heron. Fokus på ett kort (när sidan stängts) hanteras
        // som vanligt.
        if id == nil, detail != nil { return }
        guard let id, let found = locate(id) else {
            showFeatured()
            return
        }
        heroModel.focus(found.item, playlistID: playlistID)
        previewController?.focusChanged(to: found.item, playlistID: playlistID)
        heroModel.prefetchWindow(rows: rows, focusedRow: found.row, focusedIndex: found.index,
                                 playlistID: playlistID)
    }

    /// Titeln, radens index och titelns index för ett fokuserat kort.
    private func locate(_ id: CardID) -> (item: Library.LibraryItem, row: Int, index: Int)? {
        guard let rowIndex = rows.firstIndex(where: { $0.id == id.row }) else { return nil }
        let row = rows[rowIndex]
        if row.id == .continueWatching {
            guard let index = row.continueItems.firstIndex(where: { $0.id == id.itemID }) else { return nil }
            return (row.continueItems[index].libraryItem, rowIndex, index)
        }
        guard let index = row.titles.firstIndex(where: { $0.id == id.itemID }) else { return nil }
        return (row.titles[index], rowIndex, index)
    }

    /// Kör om fokushanteringen för det fokuserade kortet (efter att Hem visats igen eller spelaren stängts, då
    /// förhandsvisning och hero har släppts men fokus kan ligga kvar).
    private func refocus() {
        if let focused { handleFocus(focused) }
    }

    /// Hem lämnas eller spelaren öppnas: förhandsvisningen stoppas synkront (inget försenat stopp som kan
    /// avbryta en ny förhandsvisning efter en snabb omfokusering), en pågående Spela-start avbryts så att den inte
    /// kan öppna spelaren efteråt, och hero och förhämtning släpps. Ingen väntar på stängningen.
    private func shutDown() {
        previewController?.stopNow()
        startTask?.cancel()
        startTask = nil
        starting = false
        heroModel.reset()
    }

    // MARK: Uppspelning

    private func playContinue(_ item: ContinueWatchingItem) {
        guard presented == nil else { return }
        presented = PlayerPresentation(request: item.request,
                                       nextEpisodeProvider: model.nextEpisodeProvider(for: item.request))
    }

    // MARK: Laddning

    private func load() async {
        // Första raderna: från laddningens start tills de är publicerade (Nightly mäter `home.firstRows`).
        let signposter = Self.signposter
        let interval = rows.isEmpty ? signposter.beginInterval("home.firstRows") : nil
        defer { interval.map { signposter.endInterval("home.firstRows", $0) } }
        do {
            let loaded = try await model.homeRows(playlistID: playlistID)
            // En ersatt laddning (ny nyckel) får inte skriva över en nyare.
            guard !Task.isCancelled else { return }
            rows = loaded
            failed = false
            featuredPicks = FeaturedPicker.picks(from: loaded, limit: Self.featuredCount).map(\.item)
            featuredIndex = min(featuredIndex, max(0, featuredPicks.count - 1))
            // Inget kort har fokus (och ingen detaljsida är öppen): helskärmsheron visar den rekommenderade titeln.
            if focused == nil, detail == nil { showFeatured() }
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
        loading = false
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
