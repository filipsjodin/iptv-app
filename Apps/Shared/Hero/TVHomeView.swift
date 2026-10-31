#if os(tvOS)
import Core
import Discovery
import Library
import os
import SwiftUI

/// Hem på tvOS: titelns backdrop i helskärm (`HeroBackdrop`, med förhandsvisningen ovanpå när den spelar),
/// uppgifterna om den fokuserade titeln (`HeroInfoPanel`) i övre halvan och raderna i den nedre.
///
/// Fokus på ett kort laddar heron (`HeroModel.focus`), startar förhandsvisningen (`PreviewController.focusChanged`,
/// som själv väntar ut 1,5 s) och flyttar förhämtningsfönstret. Tappar korten fokus utan att ett annat kort får det
/// (fokus går till knapparna) stoppas förhandsvisningen; heron ligger kvar så att knapparna verkar på rätt titel.
///
/// Ett kort öppnar titelns detaljsida (`TitleDestination`) och skickar med förhandsvisningen, som sidan tar över.
///
/// Spela: en film spelas via `AppModel.playbackRequest` (samma väg, barnfilter och återupptagning som detaljsidans
/// knapp). En serie öppnar detaljsidan, som väljer rätt avsnitt (fortsätt eller S1:E1); Hem duplicerar inte
/// avsnittslogiken.
struct TVHomeView: View {
    @Environment(AppModel.self) private var model
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
    @State private var starting = false
    /// Spela-knappens start (en långsam `playbackRequest`); avbryts när Hem försvinner.
    @State private var startTask: Task<Void, Never>?
    @FocusState private var focused: CardID?

    private struct LoadKey: Equatable {
        let reloadKey: Date?
        let generation: Int
    }

    private struct CardID: Hashable {
        let row: RowID
        let itemID: String
    }

    private struct DetailTarget: Hashable {
        let kind: ContentKind
        let providerID: String
    }

    private static let signposter = OSSignposter(subsystem: "se.sjodin.iptv", category: "home")

    var body: some View {
        ZStack {
            HeroBackdrop(hero: heroModel.current, preview: previewController)
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let hero = heroModel.current {
                        HeroInfoPanel(hero: hero) { play(hero) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, 80)
                rowsView
                    .containerRelativeFrame(.vertical) { height, _ in height * 0.5 }
            }
        }
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
                             preview: previewController)
        }
    }

    // MARK: Rader

    private var rowsView: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(rows) { row in shelf(row) }
                if rows.isEmpty {
                    if loading {
                        ProgressView()
                    } else if failed {
                        Text("The library could not be read.").foregroundStyle(.secondary)
                    } else {
                        Text("Nothing here yet.").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 80)
        }
        .scrollClipDisabled()
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
            detail = DetailTarget(kind: item.kind, providerID: item.providerID)
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
            previewController?.focusChanged(to: nil, playlistID: playlistID)
            heroModel.focus(nil, playlistID: playlistID)
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

    private func play(_ hero: HeroInfo) {
        switch hero.kind {
        case .series:
            detail = DetailTarget(kind: .series, providerID: hero.providerID)
        case .movie:
            guard !starting, presented == nil else { return }
            starting = true
            startTask = Task {
                defer { starting = false }
                do {
                    let request = try await model.playbackRequest(kind: .movie, providerID: hero.providerID,
                                                                  seriesProviderID: nil, playlistID: playlistID,
                                                                  startFromBeginning: false)
                    // Hem kan ha försvunnit under den långsamma förfrågan: öppna då ingen spelare.
                    guard !Task.isCancelled else { return }
                    presented = PlayerPresentation(request: request, nextEpisodeProvider: nil)
                } catch is CancellationError {
                    return
                } catch {
                    model.lastError = UserFacingError.message(for: error)
                }
            }
        case .live:
            break
        }
    }

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
