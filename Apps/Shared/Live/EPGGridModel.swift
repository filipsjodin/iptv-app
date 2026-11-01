import Core
import Foundation
import Observation

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
    /// Nu-linjens bredd.
    var nowLineWidth: CGFloat = 2

    var totalWidth: CGFloat { CGFloat(spanHours * 60) * pointsPerMinute }

    #if os(tvOS)
    static let platform = EPGMetrics(leading: 340, rowHeight: 112, axisHeight: 56, pointsPerMinute: 8,
                                     logoSize: CGSize(width: 110, height: 66))
    #else
    static let platform = EPGMetrics(leading: 120, rowHeight: 56, axisHeight: 30, pointsPerMinute: 3.5,
                                     logoSize: CGSize(width: 48, height: 30))
    /// Regular bredd (iPad): större celler, kanalkolumn och en tydligare nu-linje.
    static let regular = EPGMetrics(leading: 168, rowHeight: 76, axisHeight: 34, pointsPerMinute: 5,
                                    logoSize: CGSize(width: 60, height: 38), nowLineWidth: 3)
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

// MARK: - Modell

/// Tablårutnätets data: program per XMLTV-kanal och timme. Hämtar bara synliga kanaler för det synliga
/// tidsfönstret ±1 timme, i omgångar utanför huvudtråden. Två grupper med samma XMLTV-id delar rader.
/// Cachen är begränsad (`channelCap` kanaler, minst nyligen använda först bort; synliga kanaler behålls).
@MainActor @Observable
final class EPGGridModel {
    struct Tick: Identifiable {
        let x: CGFloat
        let text: String
        var id: CGFloat { x }
    }

    /// Högsta antal kanaler i cachen.
    nonisolated static let channelCap = 400

    let layout: EPGGridLayout
    let metrics: EPGMetrics
    /// 30-minuterssteg (formaterade en gång).
    let ticks: [Tick]
    /// XMLTV-kanal → rutor i ordning, utan överlapp. En post (även tom) finns när kanalen lästs eller en läsning
    /// misslyckats (då är inga timmar markerade som lästa och nästa omgång försöker igen).
    private(set) var rows: [String: [EPGCell]] = [:]

    @ObservationIgnored private let appModel: AppModel
    @ObservationIgnored private let playlistID: UUID
    @ObservationIgnored private var store: [String: [String: EPGCell]] = [:]
    /// XMLTV-kanal → lästa timmar.
    @ObservationIgnored private var loaded: [String: Set<Int>] = [:]
    /// Senast använda sist.
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var revision = -1

    init(appModel: AppModel, playlistID: UUID, now: Date = Date(), metrics: EPGMetrics = .platform) {
        self.appModel = appModel
        self.playlistID = playlistID
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

    /// Timmarna (index 0..<spanHours från `origin`) som ska vara lästa: synligt fönster ±1 timme.
    nonisolated static func hourWindow(layout: EPGGridLayout, spanHours: Int, offset: CGFloat,
                                       viewport: CGFloat) -> ClosedRange<Int> {
        let range = layout.visibleRange(offset: offset, viewport: viewport)
        let last = max(0, spanHours - 1)
        let lower = min(last, max(0, Int((range.lowerBound.timeIntervalSince(layout.origin) / 3600).rounded(.down)) - 1))
        let upper = Int((range.upperBound.timeIntervalSince(layout.origin) / 3600).rounded(.up)) + 1
        return lower...max(lower, min(last, upper))
    }

    /// Kanalerna som ska kastas ur cachen: äldst först, aldrig de i `pinned`, så många att `cap` hålls.
    nonisolated static func evictionVictims(order: [String], pinned: Set<String>, cap: Int) -> [String] {
        let excess = order.count - cap
        guard excess > 0 else { return [] }
        return Array(order.lazy.filter { !pinned.contains($0) }.prefix(excess))
    }

    /// Läser det som saknas för `channels` (XMLTV-id:n) och `hours`. Nya program i databasen (`revision` ändrad)
    /// gör att allt läses om. Avbryts uppgiften (rullat bort) sparas inget för omgången som pågick.
    func ensureLoaded(channels: Set<String>, hours requested: ClosedRange<Int>, revision: Int) async {
        if revision != self.revision {
            self.revision = revision
            store = [:]
            loaded = [:]
            order = []
            rows = [:]
        }
        let last = metrics.spanHours - 1
        guard requested.lowerBound <= last else { return }
        let hours = requested.lowerBound...min(requested.upperBound, last)
        touch(channels)
        let needed = Set(hours)
        let missing = channels.filter { !(loaded[$0] ?? []).isSuperset(of: needed) }.sorted()
        guard !missing.isEmpty else { return }
        let from = layout.origin.addingTimeInterval(TimeInterval(hours.lowerBound) * 3600)
        let to = layout.origin.addingTimeInterval(TimeInterval(hours.upperBound + 1) * 3600)
        let layout = layout, playlistID = playlistID
        for start in stride(from: 0, to: missing.count, by: 12) {
            let chunk = Array(missing[start..<min(start + 12, missing.count)])
            guard !Task.isCancelled else { return }
            let programs: [String: [EPGProgram]]
            do {
                programs = try await appModel.epgPrograms(playlistID: playlistID, xmltvIDs: chunk, in: from...to)
            } catch {
                guard !Task.isCancelled else { return }
                // Läsfelet sväljs inte tyst: timmarna lämnas omarkerade (nästa ändring försöker igen) och raden
                // visar "Ingen tablå" så länge inget finns.
                for channel in chunk where rows[channel] == nil { rows[channel] = [] }
                continue
            }
            guard !Task.isCancelled else { return }
            let cells = await Task.detached(priority: .utility) {
                Self.makeCells(programs, layout: layout)
            }.value
            guard !Task.isCancelled else { return }
            for channel in chunk {
                var merged = store[channel] ?? [:]
                for cell in cells[channel] ?? [] { merged[cell.id] = cell }
                store[channel] = merged
                rows[channel] = Self.flow(Array(merged.values))
                loaded[channel, default: []].formUnion(hours)
            }
        }
    }

    /// Markerar kanalerna som senast använda och kastar ur cachen det som överstiger taket (rader, program och
    /// lästa timmar tillsammans).
    private func touch(_ channels: Set<String>) {
        order.removeAll { channels.contains($0) }
        order.append(contentsOf: channels.sorted())
        for victim in Self.evictionVictims(order: order, pinned: channels, cap: Self.channelCap) {
            store[victim] = nil
            rows[victim] = nil
            loaded[victim] = nil
            order.removeAll { $0 == victim }
        }
    }

    /// Rutor med tider, utanför huvudtråden (formateringen sker här, aldrig i `body`). Program utan synlig del
    /// (slut före rutnätets början, noll eller negativ längd) ger ingen ruta.
    nonisolated static func makeCells(_ programs: [String: [EPGProgram]], layout: EPGGridLayout)
        -> [String: [EPGCell]] {
        var result: [String: [EPGCell]] = [:]
        for (channel, list) in programs {
            result[channel] = list.compactMap { program in
                guard let frame = layout.frame(for: program) else { return nil }
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
