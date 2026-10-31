import Core
import Foundation
import Observation
import Providers
import SwiftUI

// MARK: - Mått

/// Mått för tablårutnätet (olika på tvOS och iOS).
struct EPGMetrics: Sendable {
    /// Bredd på den fastnålade kanalkolumnen.
    let leading: CGFloat
    let rowHeight: CGFloat
    let axisHeight: CGFloat
    let pointsPerMinute: CGFloat
    let logoSize: CGSize
    /// Rutnätets tidsspann från `origin`.
    let spanHours = 36

    var totalWidth: CGFloat { CGFloat(spanHours * 60) * pointsPerMinute }

    #if os(tvOS)
    static let platform = EPGMetrics(leading: 340, rowHeight: 112, axisHeight: 56, pointsPerMinute: 8,
                                     logoSize: CGSize(width: 110, height: 66))
    #else
    static let platform = EPGMetrics(leading: 120, rowHeight: 56, axisHeight: 30, pointsPerMinute: 3.5,
                                     logoSize: CGSize(width: 48, height: 30))
    #endif
}

// MARK: - Programruta

/// En programruta med färdigformaterade tider (cachade per program, aldrig formaterade i `body`).
struct EPGCell: Identifiable, Hashable, Sendable {
    /// `XMLTV-kanal|start` (sekunder): samma program får samma id oavsett vilken grupp som visar det.
    let id: String
    let program: EPGProgram
    /// Läge och bredd i rutnätet (från `EPGGridLayout.frame(for:)`).
    let x: CGFloat
    let width: CGFloat
    /// "20:00–21:00".
    let timeText: String
    /// "mån 20:00–21:00" (detaljvyn).
    let rangeText: String
    /// Efter `EPGGridModel.flow`: avstånd till föregående ruta och ritad bredd (rutorna överlappar aldrig).
    var gap: CGFloat = 0
    var drawWidth: CGFloat = 0
}

struct EPGSelection: Identifiable {
    let group: ChannelGroup
    let cell: EPGCell
    let now: Date
    var id: String { "\(group.id)\u{1F}\(cell.id)" }
}

/// tvOS: det fokuserade programmet (för sammanfattningsfältet). Cellerna skriver hit; bara fältet läser, så
/// rutnätet och raderna ritas inte om vid fokusbyten.
@MainActor @Observable
final class EPGFocusTracker {
    var focused: EPGSelection?
}

// MARK: - Modell

/// Tablårutnätets data: program per XMLTV-kanal och timme. Hämtar bara synliga kanaler för det synliga
/// tidsfönstret ±1 timme, i omgångar utanför huvudtråden. Två grupper med samma XMLTV-id delar rader.
@MainActor @Observable
final class EPGGridModel {
    struct Tick: Identifiable {
        let x: CGFloat
        let text: String
        var id: CGFloat { x }
    }

    private struct Bucket: Hashable {
        let channel: String
        let hour: Int
    }

    let layout: EPGGridLayout
    let metrics: EPGMetrics
    /// 30-minuterssteg (formaterade en gång).
    let ticks: [Tick]
    /// XMLTV-kanal → rutor i ordning, utan överlapp. En post (även tom) finns när kanalen lästs.
    private(set) var rows: [String: [EPGCell]] = [:]

    @ObservationIgnored private let appModel: AppModel
    @ObservationIgnored private let playlistID: UUID
    @ObservationIgnored private var store: [String: [String: EPGCell]] = [:]
    @ObservationIgnored private var loaded: Set<Bucket> = []
    @ObservationIgnored private var revision = -1

    init(appModel: AppModel, playlistID: UUID, now: Date = Date()) {
        self.appModel = appModel
        self.playlistID = playlistID
        let metrics = EPGMetrics.platform
        self.metrics = metrics
        // Hel halvtimme, två timmar före nu.
        let half = (now.timeIntervalSince1970 / 1800).rounded(.down) * 1800
        let layout = EPGGridLayout(origin: Date(timeIntervalSince1970: half - 2 * 3600),
                                   pointsPerMinute: metrics.pointsPerMinute)
        self.layout = layout
        ticks = (0..<(metrics.spanHours * 2)).map { step in
            let date = layout.origin.addingTimeInterval(TimeInterval(step) * 1800)
            return Tick(x: layout.x(for: date), text: date.formatted(date: .omitted, time: .shortened))
        }
    }

    /// Där rutnätet börjar rullat: en kvart före nu.
    func initialOffset(now: Date) -> CGFloat {
        max(0, layout.x(for: now.addingTimeInterval(-15 * 60)))
    }

    /// Timmarna (index från `origin`) som ska vara lästa: synligt fönster ±1 timme.
    nonisolated static func hourWindow(layout: EPGGridLayout, spanHours: Int, offset: CGFloat,
                                       viewport: CGFloat) -> ClosedRange<Int> {
        let range = layout.visibleRange(offset: offset, viewport: viewport)
        let lower = max(0, Int((range.lowerBound.timeIntervalSince(layout.origin) / 3600).rounded(.down)) - 1)
        let upper = Int((range.upperBound.timeIntervalSince(layout.origin) / 3600).rounded(.up)) + 1
        return lower...max(lower, min(spanHours, upper))
    }

    /// Läser det som saknas för `channels` (XMLTV-id:n) och `hours`. Nya program i databasen (`revision` ändrad)
    /// gör att allt läses om. Avbryts uppgiften (rullat bort) sparas inget för omgången som pågick.
    func ensureLoaded(channels: Set<String>, hours: ClosedRange<Int>, revision: Int) async {
        if revision != self.revision {
            self.revision = revision
            store = [:]
            loaded = []
            rows = [:]
        }
        let missing = channels.filter { channel in
            hours.contains { !loaded.contains(Bucket(channel: channel, hour: $0)) }
        }.sorted()
        guard !missing.isEmpty else { return }
        let from = layout.origin.addingTimeInterval(TimeInterval(hours.lowerBound) * 3600)
        let to = layout.origin.addingTimeInterval(TimeInterval(hours.upperBound + 1) * 3600)
        let layout = layout, playlistID = playlistID
        for start in stride(from: 0, to: missing.count, by: 12) {
            let chunk = Array(missing[start..<min(start + 12, missing.count)])
            guard !Task.isCancelled else { return }
            guard let programs = try? await appModel.epgPrograms(playlistID: playlistID, xmltvIDs: chunk,
                                                                 in: from...to),
                  !Task.isCancelled else { return }
            let cells = await Task.detached(priority: .utility) {
                Self.makeCells(programs, layout: layout)
            }.value
            guard !Task.isCancelled else { return }
            for channel in chunk {
                var merged = store[channel] ?? [:]
                for cell in cells[channel] ?? [] { merged[cell.id] = cell }
                store[channel] = merged
                rows[channel] = Self.flow(Array(merged.values))
                for hour in hours { loaded.insert(Bucket(channel: channel, hour: hour)) }
            }
        }
    }

    /// Rutor med tider, utanför huvudtråden (formateringen sker här, aldrig i `body`).
    nonisolated static func makeCells(_ programs: [String: [EPGProgram]], layout: EPGGridLayout)
        -> [String: [EPGCell]] {
        var result: [String: [EPGCell]] = [:]
        for (channel, list) in programs {
            result[channel] = list.map { program in
                let frame = layout.frame(for: program)
                let start = program.start.formatted(date: .omitted, time: .shortened)
                let end = program.end.formatted(date: .omitted, time: .shortened)
                let day = program.start.formatted(.dateTime.weekday(.abbreviated))
                return EPGCell(id: "\(channel)|\(Int(program.start.timeIntervalSince1970))", program: program,
                               x: frame.x, width: frame.width, timeText: "\(start)–\(end)",
                               rangeText: "\(day) \(start)–\(end)")
            }
        }
        return result
    }

    /// Sorterar rutorna och räknar ut avstånd och ritad bredd så att de inte överlappar (dubbletter eller
    /// minimibredd kan annars skjuta in i nästa ruta). Fullt överlappade rutor utelämnas.
    nonisolated static func flow(_ cells: [EPGCell]) -> [EPGCell] {
        var cursor: CGFloat = 0
        var result: [EPGCell] = []
        for var cell in cells.sorted(by: { ($0.x, $0.id) < ($1.x, $1.id) }) {
            let start = max(cell.x, cursor)
            let width = cell.x + cell.width - start
            guard width >= 1 else { continue }
            cell.gap = start - cursor
            cell.drawWidth = width
            cursor = start + width
            result.append(cell)
        }
        return result
    }
}

// MARK: - Vy

/// TV-tablån: kanaler vertikalt (`LazyVStack`, bara synliga rader byggs), tid horisontellt i en gemensam
/// tvådimensionell rullning så att alla rader hålls tidsjusterade. Kanalkolumnen och tidsaxeln sitter fast. En
/// "nu"-linje. Valt program öppnar `ProgramDetailView`.
struct EPGGridView: View {
    let appModel: AppModel
    let live: LiveModel
    let playlistID: UUID
    /// Spelar kanalen (som kanallistan gör); anropas först när detaljvyn stängts.
    let play: (ChannelGroup) -> Void

    @State private var grid: EPGGridModel
    @State private var tracker = EPGFocusTracker()
    /// Synliga rader (radnyckel → grupp-id); en grupp kan visas i flera sektioner.
    @State private var visibleRows: [String: String] = [:]
    @State private var hours: ClosedRange<Int>
    @State private var position: ScrollPosition
    @State private var now = Date()
    @State private var selection: EPGSelection?
    @State private var pendingWatch: ChannelGroup?

    init(appModel: AppModel, live: LiveModel, playlistID: UUID, play: @escaping (ChannelGroup) -> Void) {
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
        _hours = State(initialValue: EPGGridModel.hourWindow(layout: model.layout, spanHours: model.metrics.spanHours,
                                                             offset: offset, viewport: 1800))
    }

    private struct LoadKey: Hashable {
        let groups: Set<String>
        let hours: ClosedRange<Int>
        let epgVersion: Int
        let revision: Int
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
                                row(group, section: section, metrics: metrics)
                            }
                        }
                    } header: {
                        axis(metrics: metrics)
                    }
                }
                .overlay(alignment: .topLeading) { nowLine(metrics: metrics, layout: layout) }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: ClosedRange<Int>.self) { geometry in
                EPGGridModel.hourWindow(layout: layout, spanHours: metrics.spanHours,
                                        offset: geometry.contentOffset.x,
                                        viewport: geometry.containerSize.width - metrics.leading)
            } action: { _, window in
                hours = window
            }
        }
        .accessibilityLabel("Channel guide")
        .task(id: loadKey) {
            // Rullning pågår: vänta kort (uppgiften avbryts och startas om vid nästa ändring).
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let channels = Set(visibleRows.values.compactMap { live.epgChannelID(for: $0) })
            await grid.ensureLoaded(channels: channels, hours: hours, revision: appModel.epgRevision)
        }
        // Nu-linjen och "sänds nu" följer klockan.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
        .sheet(item: $selection, onDismiss: {
            // Spelaren öppnas först när detaljvyn stängts (ett helskärmsöverlägg över ett blad går inte).
            if let group = pendingWatch {
                pendingWatch = nil
                play(group)
            }
        }, content: { item in
            ProgramDetailView(group: item.group, cell: item.cell, now: item.now,
                              watch: { pendingWatch = item.group; selection = nil },
                              close: { selection = nil })
        })
    }

    private var loadKey: LoadKey {
        LoadKey(groups: Set(visibleRows.values), hours: hours, epgVersion: live.epgVersion,
                revision: appModel.epgRevision)
    }

    private func row(_ group: ChannelGroup, section: LiveModel.Section, metrics: EPGMetrics) -> some View {
        let key = "\(section.id)\u{1F}\(group.id)"
        let channel = live.epgChannelID(for: group.id)
        return EPGRow(group: group, cells: channel.flatMap { grid.rows[$0] }, hasGuide: channel != nil, now: now,
                      metrics: metrics, tracker: tracker,
                      select: { group, cell in selection = EPGSelection(group: group, cell: cell, now: Date()) })
            .onAppear { visibleRows[key] = group.id }
            .onDisappear { visibleRows[key] = nil }
    }

    private func axis(metrics: EPGMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(grid.ticks) { tick in
                Text(verbatim: tick.text).font(.caption).foregroundStyle(.secondary)
                    .offset(x: metrics.leading + tick.x + 6, y: 6)
            }
        }
        .frame(width: metrics.leading + metrics.totalWidth, height: metrics.axisHeight, alignment: .topLeading)
        .background(.background)
    }

    @ViewBuilder private func nowLine(metrics: EPGMetrics, layout: EPGGridLayout) -> some View {
        let x = layout.nowX(now)
        if x >= 0, x < metrics.totalWidth {
            Rectangle().fill(.red).frame(width: 2)
                .offset(x: metrics.leading + x)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Rad

/// En kanalrad: fastnålad logga och namn till vänster, programrutor i tidsordning. Utan program: "Ingen tablå".
private struct EPGRow: View {
    let group: ChannelGroup
    /// `nil` = inte läst än (eller kanalen saknar koppling).
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
                Color.clear.frame(width: metrics.leading, height: 1)
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
        .frame(width: metrics.leading + metrics.totalWidth, height: metrics.rowHeight, alignment: .leading)
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
            if isFocused { tracker.focused = EPGSelection(group: group, cell: cell, now: Date()) }
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
    /// Håller elementet kvar vid vänsterkanten när rutnätet rullas i sidled.
    func pinnedToLeading() -> some View {
        visualEffect { content, proxy in
            content.offset(x: max(0, -proxy.frame(in: .scrollView).minX))
        }
    }
}
