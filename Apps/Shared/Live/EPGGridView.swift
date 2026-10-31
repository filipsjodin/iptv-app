import Core
import Foundation
import Observation
import Providers
import SwiftUI

// MARK: - Delat tillstånd

/// Valt program (detaljvyn). `zapGroups` är sektionen kanalen valdes i (zapplistan när den spelas).
struct EPGSelection: Identifiable {
    let group: ChannelGroup
    let cell: EPGCell
    let zapGroups: [ChannelGroup]
    let now: Date
    var id: String { "\(group.id)\u{1F}\(cell.id)" }
}

/// tvOS: det fokuserade programmet (för sammanfattningsfältet). Cellerna skriver hit; bara fältet läser, så
/// rutnätet och raderna ritas inte om vid fokusbyten.
@MainActor @Observable
final class EPGFocusTracker {
    struct Focus {
        let group: ChannelGroup
        let cell: EPGCell
    }

    var focused: Focus?
}

/// Rutnätets synlighet och klocka. Raderna skriver hit i `onAppear`/`onDisappear` utan att något observerar
/// mängden; bara en liten, fördröjd `version` publiceras när mängden ändrats. Rutnätets `body` läser inget härifrån
/// (det gör bara de små vyerna `EPGLoadTrigger`, `EPGRowHost` och `EPGNowLine`), så ingen rullningshändelse kör
/// något som är proportionellt mot antalet kanaler.
@MainActor @Observable
final class EPGViewState {
    private(set) var version = 0
    /// Timmarna som ska vara lästa (synligt fönster ±1 timme).
    var hours: ClosedRange<Int>
    var now = Date()

    @ObservationIgnored private var rows: [String: String] = [:]
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    init(hours: ClosedRange<Int>) {
        self.hours = hours
    }

    /// Grupp-id:n för de synliga raderna (ögonblicksbild).
    var visibleGroupIDs: Set<String> { Set(rows.values) }

    func appear(key: String, groupID: String) {
        guard rows.updateValue(groupID, forKey: key) != groupID else { return }
        schedulePublish()
    }

    func disappear(key: String) {
        guard rows.removeValue(forKey: key) != nil else { return }
        schedulePublish()
    }

    func stop() {
        publishTask?.cancel()
    }

    private func schedulePublish() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.version += 1
        }
    }
}

// MARK: - Vy

/// TV-tablån: kanaler vertikalt (`LazyVStack`, bara synliga rader byggs), tid horisontellt i en gemensam
/// tvådimensionell rullning så att alla rader hålls tidsjusterade. Kanalkolumnen och tidsaxeln sitter fast.
/// Innehållet börjar efter kanalkolumnen (`contentMargins`), så att inget börjar under den. En "nu"-linje.
/// Valt program öppnar `ProgramDetailView`.
struct EPGGridView: View {
    let appModel: AppModel
    let live: LiveModel
    let playlistID: UUID
    /// Spelar kanalen med zapplistan (sektionens kanaler), som kanallistan gör; anropas först när detaljvyn
    /// stängts.
    let play: (ChannelGroup, [ChannelGroup]) -> Void

    @State private var grid: EPGGridModel
    @State private var tracker = EPGFocusTracker()
    @State private var state: EPGViewState
    @State private var position: ScrollPosition
    @State private var selection: EPGSelection?
    @State private var pendingWatch: EPGSelection?

    init(appModel: AppModel, live: LiveModel, playlistID: UUID, play: @escaping (ChannelGroup, [ChannelGroup]) -> Void) {
        self.appModel = appModel
        self.live = live
        self.playlistID = playlistID
        self.play = play
        let start = Date()
        let model = EPGGridModel(appModel: appModel, playlistID: playlistID, now: start)
        let offset = model.initialOffset(now: start)
        _grid = State(initialValue: model)
        _position = State(initialValue: ScrollPosition(point: CGPoint(x: offset, y: 0)))
        // Tills rullningen rapporterat sin storlek: ett normalt fönster från startläget.
        _state = State(initialValue: EPGViewState(
            hours: EPGGridModel.hourWindow(layout: model.layout, spanHours: model.metrics.spanHours,
                                           offset: offset, viewport: 1800)))
    }

    var body: some View {
        let metrics = grid.metrics
        let layout = grid.layout
        VStack(spacing: 0) {
            #if os(tvOS)
            EPGFocusSummary(tracker: tracker)
            #endif
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(live.sections) { section in
                            Text(verbatim: section.title).font(.headline)
                                .frame(height: metrics.rowHeight * 0.6)
                                .pinnedToLeading()
                            ForEach(section.groups, id: \.id) { group in
                                EPGRowHost(group: group, sectionID: section.id, zapGroups: section.groups,
                                           grid: grid, live: live, state: state, metrics: metrics,
                                           tracker: tracker, select: { selection = $0 })
                            }
                        }
                    } header: {
                        axis(metrics: metrics)
                    }
                }
                // Bakom raderna: den fastnålade kanalkolumnen (ogenomskinlig) täcker linjen.
                .background(alignment: .topLeading) { EPGNowLine(state: state, layout: layout, metrics: metrics) }
            }
            // Innehållet börjar efter kanalkolumnen; fokus och rullning håller sig utanför den.
            .contentMargins(.leading, metrics.leading, for: .scrollContent)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ClosedRange<Int>.self) { geometry in
                EPGGridModel.hourWindow(layout: layout, spanHours: metrics.spanHours,
                                        offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                                        viewport: geometry.containerSize.width - metrics.leading)
            } action: { _, window in
                if state.hours != window { state.hours = window }
            }
        }
        .accessibilityLabel("Channel guide")
        .background { EPGLoadTrigger(appModel: appModel, live: live, grid: grid, state: state) }
        // Nu-linjen och "sänds nu" följer klockan.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                state.now = Date()
            }
        }
        .onDisappear { state.stop() }
        .sheet(item: $selection, onDismiss: {
            // Spelaren öppnas först när detaljvyn stängts (ett helskärmsöverlägg över ett blad går inte).
            if let item = pendingWatch {
                pendingWatch = nil
                play(item.group, item.zapGroups)
            }
        }, content: { item in
            ProgramDetailView(group: item.group, cell: item.cell, now: item.now,
                              watch: { pendingWatch = item; selection = nil },
                              close: { selection = nil })
        })
    }

    private func axis(metrics: EPGMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(grid.ticks) { tick in
                Text(verbatim: tick.text).font(.caption).foregroundStyle(.secondary)
                    .offset(x: tick.x + 6, y: 6)
            }
            // Hörn över kanalkolumnen: tidsaxelns etiketter syns aldrig ovanpå den.
            Rectangle().fill(.background)
                .frame(width: metrics.leading, height: metrics.axisHeight)
                .pinnedToLeading()
        }
        .frame(width: metrics.totalWidth, height: metrics.axisHeight, alignment: .topLeading)
        .background(.background)
    }
}

/// Läser tablåprogram för synliga kanaler och timmar. Egen vy så att rutnätets `body` inte beror på
/// synligheten; uppgiften startas om (och den förra avbryts) när något av det ändras.
private struct EPGLoadTrigger: View {
    let appModel: AppModel
    let live: LiveModel
    let grid: EPGGridModel
    let state: EPGViewState

    private struct Key: Hashable {
        let version: Int
        let hours: ClosedRange<Int>
        let epgVersion: Int
        let revision: Int
    }

    var body: some View {
        let key = Key(version: state.version, hours: state.hours, epgVersion: live.epgVersion,
                      revision: appModel.epgRevision)
        Color.clear.frame(width: 0, height: 0)
            .task(id: key) {
                // Rullning pågår: vänta kort så att uppgiften hinner avbrytas vid nästa ändring.
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let channels = Set(state.visibleGroupIDs.compactMap { live.epgChannelID(for: $0) })
                await grid.ensureLoaded(channels: channels, hours: state.hours, revision: appModel.epgRevision)
            }
    }
}

/// "Nu"-linjen, ritad bakom raderna.
private struct EPGNowLine: View {
    let state: EPGViewState
    let layout: EPGGridLayout
    let metrics: EPGMetrics

    var body: some View {
        let x = layout.nowX(state.now)
        if x >= 0, x < metrics.totalWidth {
            Rectangle().fill(.red).frame(width: 2)
                .offset(x: x)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Rad

/// Läser radens data (XMLTV-koppling, program, klocka) själv, så att bara de synliga raderna ritas om när
/// de ändras och rutnätets `body` slipper det.
private struct EPGRowHost: View {
    let group: ChannelGroup
    let sectionID: String
    let zapGroups: [ChannelGroup]
    let grid: EPGGridModel
    let live: LiveModel
    let state: EPGViewState
    let metrics: EPGMetrics
    let tracker: EPGFocusTracker
    let select: (EPGSelection) -> Void

    var body: some View {
        // Kopplingen läses om (`epgVersion`) när tablån eller kanalgrupperna ändrats.
        let _ = live.epgVersion
        let channel = live.epgChannelID(for: group.id)
        let key = "\(sectionID)\u{1F}\(group.id)"
        EPGRow(group: group, cells: channel.flatMap { grid.rows[$0] }, hasGuide: channel != nil, now: state.now,
               metrics: metrics, tracker: tracker,
               select: { group, cell in
                   select(EPGSelection(group: group, cell: cell, zapGroups: zapGroups, now: Date()))
               })
            .onAppear { state.appear(key: key, groupID: group.id) }
            .onDisappear { state.disappear(key: key) }
    }
}

/// En kanalrad: fastnålad logga och namn till vänster, programrutor i tidsordning. Utan program: "Ingen tablå".
private struct EPGRow: View {
    let group: ChannelGroup
    /// `nil` = inte läst än.
    let cells: [EPGCell]?
    /// Gruppen har en XMLTV-koppling.
    let hasGuide: Bool
    let now: Date
    let metrics: EPGMetrics
    let tracker: EPGFocusTracker
    let select: (ChannelGroup, EPGCell) -> Void

    private var isEmpty: Bool { !hasGuide || cells?.isEmpty == true }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(cells ?? []) { cell in
                    if cell.gap > 0 { Color.clear.frame(width: cell.gap, height: 1) }
                    EPGCellButton(group: group, cell: cell, airing: cell.program.start <= now && now < cell.program.end,
                                  rowHeight: metrics.rowHeight, tracker: tracker, select: select)
                }
            }
            HStack(spacing: 12) {
                ChannelLogoView(group: group, size: metrics.logoSize)
                if isEmpty {
                    Text("No guide available").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(verbatim: group.displayName).font(.caption).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minWidth: metrics.leading, maxWidth: isEmpty ? nil : metrics.leading, minHeight: metrics.rowHeight,
                   maxHeight: metrics.rowHeight, alignment: .leading)
            .fixedSize(horizontal: isEmpty, vertical: false)
            .background(.background)
            .pinnedToLeading()
        }
        .frame(width: metrics.totalWidth, height: metrics.rowHeight, alignment: .leading)
    }
}

/// En programruta. tvOS: fokusbar (kortstil); fokus skrivs till `tracker` (ingen tillståndsändring i raden).
/// iOS: tryck.
private struct EPGCellButton: View {
    let group: ChannelGroup
    let cell: EPGCell
    let airing: Bool
    let rowHeight: CGFloat
    let tracker: EPGFocusTracker
    let select: (ChannelGroup, EPGCell) -> Void

    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    var body: some View {
        Button { select(group, cell) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: cell.program.title).font(.caption.weight(airing ? .bold : .regular)).lineLimit(2)
                Text(verbatim: cell.timeText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(width: max(1, cell.drawWidth - 6), height: rowHeight - 8, alignment: .leading)
            .clipped()
        }
        #if os(tvOS)
        .buttonStyle(.card)
        .focused($focused)
        .onChange(of: focused) { _, isFocused in
            if isFocused { tracker.focused = EPGFocusTracker.Focus(group: group, cell: cell) }
        }
        #else
        .buttonStyle(.plain)
        .background(airing ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 6))
        #endif
        .frame(width: cell.drawWidth, height: rowHeight, alignment: .leading)
        .accessibilityLabel(Text(verbatim: "\(cell.program.title), \(cell.timeText)"))
    }
}

#if os(tvOS)
/// tvOS: det fokuserade programmets titel, tid och beskrivning över rutnätet (fast höjd, så att rutnätet inte hoppar).
private struct EPGFocusSummary: View {
    let tracker: EPGFocusTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let item = tracker.focused {
                Text(verbatim: item.cell.program.title).font(.title3.bold()).lineLimit(1)
                Text(verbatim: "\(item.group.displayName) · \(item.cell.rangeText)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Text(verbatim: item.cell.program.summary ?? "").font(.callout).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .padding(.horizontal, 40)
    }
}
#endif

private extension View {
    /// Håller elementet vid rutnätets vänsterkant (kanalkolumnen) när det rullas i sidled: placeringen i
    /// rullningsvyns koordinater tvingas till 0. Ingen tillståndsändring och ingen omritning av `body`.
    func pinnedToLeading() -> some View {
        visualEffect { content, proxy in
            content.offset(x: -proxy.frame(in: .scrollView).minX)
        }
    }
}
