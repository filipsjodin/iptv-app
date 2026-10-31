import Core
import Foundation
import Library
import Personal
import Providers

// MARK: - Live: kanalgrupper, tablå och personliga kanallistor

/// Korta tablån per kanal i minnet. Ett tomt svar sparas också, så att en kanal utan tablå inte frågas om vid
/// varje uppdatering.
final class ShortEPGCache: @unchecked Sendable {
    static let lifetime: TimeInterval = 5 * 60
    /// Högsta antal poster; vid överskridande slängs den minst nyligen använda.
    static let defaultCapacity = 500
    private struct Entry {
        let fetchedAt: Date
        let value: NowNext?
        var lastUsed: Int
    }
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var useCounter = 0

    init(capacity: Int = ShortEPGCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Antal poster i cachen (för tester).
    var count: Int { lock.withLock { entries.count } }

    /// `.some(nil)` betyder "hämtad nyligen, ingen tablå"; `nil` betyder att den måste hämtas.
    func cached(_ key: String, at date: Date) -> NowNext?? {
        lock.withLock {
            guard var entry = entries[key], date >= entry.fetchedAt,
                  date.timeIntervalSince(entry.fetchedAt) < Self.lifetime else { return nil }
            useCounter += 1
            entry.lastUsed = useCounter
            entries[key] = entry
            return .some(entry.value)
        }
    }

    func store(_ value: NowNext?, for key: String, at date: Date) {
        lock.withLock {
            useCounter += 1
            entries[key] = Entry(fetchedAt: date, value: value, lastUsed: useCounter)
            // Gränsen gäller även utgångna poster: de som använts längst sedan går först.
            while entries.count > capacity, let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
                entries[oldest.key] = nil
            }
        }
    }
}

extension AppModel {
    /// Efter ett misslyckat eller tomt försök väntar vi så här länge innan nästa hämtning av samma spellista.
    nonisolated static let epgRetryBackoff: TimeInterval = 30 * 60
    /// Högsta antal kanaler som frågas via korta tablån per uppdatering.
    nonisolated static let shortEPGBatchLimit = 24
    /// Högsta antal samtidiga förfrågningar mot leverantören för korta tablån.
    nonisolated static let shortEPGConcurrency = 4

    // MARK: Kanaler

    /// Spellistans kanalgrupper med den manuella uppdelningen. Tomt i barnläge (och utan vald profil).
    func liveGroups(playlistID: UUID) async throws -> [ChannelGroup] {
        guard !kidsRestricted else { return [] }
        let store = store, epg = epg
        return try await offMain {
            // Samma uppdelning som importen använder vid matchningen, så att gruppering och tablå är överens.
            let splits = try epg.splitProviderIDs(playlistID: playlistID)
            return try store.channelGroups(playlistID: playlistID, splitProviderIDs: splits)
        }
    }

    /// Spellistans live-kategorier i leverantörens ordning. Tomt i barnläge.
    func liveCategories(playlistID: UUID) async -> [Core.Category] {
        guard !kidsRestricted else { return [] }
        let store = store
        return (try? await offMain { try store.categories(playlistID: playlistID, kind: .live) }) ?? []
    }

    /// Delar upp en variant till en egen kanal (`split`) eller slår ihop den med gruppen igen. Gruppernas id
    /// ändras, så anroparen läser om grupperna. Barnläge: ingen ändring.
    /// Tablåkopplingen görs om: hämtningstiden nollställs och en ny hämtning startas (med 30 minuters väntan efter
    /// ett misslyckande), annars saknar en namnmatchad kanal sin tablå i upp till 12 timmar.
    func splitChannel(playlistID: UUID, providerID: String, split: Bool) async {
        guard !kidsRestricted else { return }
        let epg = epg
        try? await offMain { try epg.setSplit(playlistID: playlistID, providerID: providerID, split: split) }
        await resetEPGFetchTime(playlistID: playlistID)
        await refreshEPGIfNeeded(playlistID: playlistID)
    }

    /// Nollställer tablåns hämtningstid (program och koppling består tills nästa hämtning är sparad), så att nästa
    /// uppdatering körs direkt. Anropas när kanalerna ändrats (uppdelning, ny import).
    func resetEPGFetchTime(playlistID: UUID) async {
        let epg = epg
        try? await offMain { try epg.resetFetchTime(playlistID: playlistID) }
    }

    // MARK: Tablå

    /// Grupp-id → XMLTV-kanal. Läser kopplingen som den senaste slutförda importen sparade (id- och namnmatchning).
    /// Grupper som saknas i den sparade kopplingen (före den första importen, eller nyss uppdelade) får sin egen
    /// `epgChannelID` om de har en (inga databasfrågor per kanal). Tomt i barnläge, och vid ett läsfel ges ingen
    /// koppling.
    func epgMap(playlistID: UUID, groups: [ChannelGroup]) async -> [String: String] {
        guard !kidsRestricted, !groups.isEmpty else { return [:] }
        let epg = epg
        guard let stored = try? await offMain({ try epg.channelMap(playlistID: playlistID) }) else { return [:] }
        var map = stored
        for group in groups where map[group.id] == nil {
            if let id = group.variants.lazy.compactMap(\.epgChannelID).first { map[group.id] = id }
        }
        return map
    }

    /// Pågående och nästa program för de efterfrågade XMLTV-kanalerna (bara dem). Tomt i barnläge.
    func nowNext(playlistID: UUID, xmltvIDs: [String], at date: Date) async -> [String: NowNext] {
        guard !kidsRestricted, !xmltvIDs.isEmpty else { return [:] }
        let epg = epg
        return (try? await offMain { try epg.nowNext(playlistID: playlistID, channelIDs: xmltvIDs, at: date) }) ?? [:]
    }

    /// Program som överlappar `range` för de efterfrågade XMLTV-kanalerna (tablårutnätet; bara dem). Tomt i barnläge.
    /// Läsfel kastas, så att anroparen kan försöka igen i stället för att tro att kanalen saknar tablå.
    func epgPrograms(playlistID: UUID, xmltvIDs: [String], in range: ClosedRange<Date>) async throws
        -> [String: [EPGProgram]] {
        guard !kidsRestricted, !xmltvIDs.isEmpty else { return [:] }
        let epg = epg
        return try await offMain { try epg.programs(playlistID: playlistID, channelIDs: xmltvIDs, in: range) }
    }

    /// Reserv för Xtream-kanaler utan lagrad tablå: `get_short_epg` per grupp (bästa varianten först i listan),
    /// cachad i minnet i 5 minuter. Resultatet har grupp-id som nyckel. Hemligheten läses via den vanliga
    /// Keychain-vägen utanför huvudaktören; URL:er och inloggning loggas aldrig och fel ger bara ingen post.
    /// Högst `shortEPGBatchLimit` kanaler per anrop. Tomt i barnläge och för M3U-spellistor.
    func shortNowNext(playlistID: UUID, groups: [ChannelGroup], at date: Date) async -> [String: NowNext] {
        guard !kidsRestricted, !groups.isEmpty else { return [:] }
        let cache = shortEPGCache
        var result: [String: NowNext] = [:]
        var targets: [ShortEPGTarget] = []
        // Träffar i cachen kostar inget och räknas inte mot gränsen; gränsen gäller kanaler som ska hämtas.
        for group in groups {
            guard case let .xtream(_, streamID, _) = group.variants.first?.locator else { continue }
            if let hit = cache.cached("\(playlistID)|\(streamID)", at: date) {
                if let value = hit { result[group.id] = value }
            } else if targets.count < Self.shortEPGBatchLimit {
                targets.append(ShortEPGTarget(groupID: group.id, streamID: streamID))
            }
        }
        guard !targets.isEmpty else { return result }
        let credentials = credentials, http = http
        let fetched = await Task.detached(priority: .utility) {
            await Self.fetchShortNowNext(playlistID: playlistID, targets: targets, at: date, cache: cache,
                                         credentials: credentials, http: http)
        }.value
        return result.merging(fetched) { current, _ in current }
    }

    nonisolated private static func fetchShortNowNext(playlistID: UUID, targets: [ShortEPGTarget], at date: Date,
                                                      cache: ShortEPGCache, credentials: CredentialStore,
                                                      http: HTTPClient) async -> [String: NowNext] {
        var result: [String: NowNext] = [:]
        var missing: [ShortEPGTarget] = []
        for target in targets {
            if let hit = cache.cached("\(playlistID)|\(target.streamID)", at: date) {
                if let value = hit { result[target.groupID] = value }
            } else {
                missing.append(target)
            }
        }
        guard !missing.isEmpty,
              case let .xtream(server, username, password)? = try? credentials.load(for: playlistID)
        else { return result }
        let client = XtreamClient(server: server, username: username, password: password, http: http)
        let fetched = await fetchShortEPGResults(targets: missing) { target in
            guard let programs = try? await client.shortEPG(streamID: target.streamID, limit: 4) else { return nil }
            return nowNext(from: programs, at: date)
        }
        for item in fetched {
            // Ett fel cachas inte; en tom tablå gör det.
            if item.succeeded { cache.store(item.value, for: "\(playlistID)|\(item.target.streamID)", at: date) }
            if let value = item.value { result[item.target.groupID] = value }
        }
        return result
    }

    /// Hämtar för alla mål med högst `concurrency` förfrågningar åt gången: en ny startas först när en tidigare är
    /// klar. `fetch` ger `nil` vid fel (cachas inte) och annars programmen, där `.some(nil)` betyder tom tablå.
    nonisolated static func fetchShortEPGResults(
        targets: [ShortEPGTarget], concurrency: Int = AppModel.shortEPGConcurrency,
        fetch: @escaping @Sendable (ShortEPGTarget) async -> NowNext??
    ) async -> [ShortEPGResult] {
        let work: @Sendable (ShortEPGTarget) async -> ShortEPGResult = { target in
            guard let outcome = await fetch(target) else {
                return ShortEPGResult(target: target, value: nil, succeeded: false)
            }
            return ShortEPGResult(target: target, value: outcome, succeeded: true)
        }
        return await withTaskGroup(of: ShortEPGResult.self) { group in
            var iterator = targets.makeIterator()
            var started = 0
            while started < max(1, concurrency), let target = iterator.next() {
                group.addTask { await work(target) }
                started += 1
            }
            var all: [ShortEPGResult] = []
            for await item in group {
                all.append(item)
                if let target = iterator.next() { group.addTask { await work(target) } }
            }
            return all
        }
    }

    /// Pågående (`start <= at < end`) och nästa program ur en lista; `nil` när inget av dem finns.
    nonisolated static func nowNext(from programs: [EPGProgram], at date: Date) -> NowNext? {
        let sorted = programs.sorted { $0.start < $1.start }
        let current = sorted.last { $0.start <= date && date < $0.end }
        let after = current?.end ?? date
        let next = sorted.first { $0.start >= after }
        guard current != nil || next != nil else { return nil }
        return NowNext(now: current, next: next)
    }

    // MARK: Uppdatering

    /// Sant när en ny hämtning är tillåten: inget misslyckat eller tomt försök de senaste 30 minuterna.
    nonisolated static func epgRetryAllowed(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return true }
        return now.timeIntervalSince(lastFailure) >= epgRetryBackoff || now < lastFailure
    }

    /// Startar tablåhämtningen i bakgrunden när Live-fliken öppnas, om den behövs (aldrig hämtad eller äldre än
    /// 12 timmar) och spellistan har en tablåkälla. Aldrig i barnläge, aldrig när en hämtning redan pågår och
    /// inte inom 30 minuter efter ett misslyckat eller tomt försök (en hämtning som ger 0 program uppdaterar inte
    /// `lastFetch`). Efter en lyckad hämtning ökas `epgRevision`. Returnerar uppgiften (för tester) eller `nil`.
    @discardableResult
    func refreshEPGIfNeeded(playlistID: UUID) async -> Task<Void, Never>? {
        guard !kidsRestricted, epgRefreshTasks[playlistID] == nil,
              Self.epgRetryAllowed(lastFailure: epgRefreshFailures[playlistID], now: now()) else { return nil }
        let importer = epgImporter, credentials = credentials
        let due = (try? await offMain { () throws -> Bool in
            guard importer.needsRefresh(playlistID: playlistID),
                  let secret = try credentials.load(for: playlistID),
                  EPGSource.url(for: secret) != nil else { return false }
            return true
        }) ?? false
        // Läget kan ha ändrats under väntan (profilbyte, en annan körning).
        guard due, !kidsRestricted, epgRefreshTasks[playlistID] == nil else { return nil }
        let task = Task { [weak self] in
            let outcome: Result<Int, Error>
            do { outcome = .success(try await importer.refresh(playlistID: playlistID)) } catch { outcome = .failure(error) }
            guard let self else { return }
            self.epgRefreshTasks[playlistID] = nil
            switch outcome {
            case let .success(count) where count > 0:
                self.epgRefreshFailures[playlistID] = nil
                self.epgRevision += 1
            case let .failure(error) where error is CancellationError:
                break
            default:
                self.epgRefreshFailures[playlistID] = self.now()
            }
        }
        epgRefreshTasks[playlistID] = task
        return task
    }

    // MARK: Favoriter och senast sedda (aktiv profil)

    /// Favoritkanalernas grupp-id, nyast först. Tomt i barnläge.
    func favoriteChannelIDs() -> [String] {
        _ = personalRevision
        guard !kidsRestricted else { return [] }
        return activeProfile?.personal.favoriteChannels() ?? []
    }

    /// Senast sedda kanalers grupp-id, nyast först. Tomt i barnläge.
    func recentChannelIDs() -> [String] {
        _ = personalRevision
        guard !kidsRestricted else { return [] }
        return activeProfile?.personal.recentChannels() ?? []
    }

    /// Lägger till eller tar bort kanalgruppen bland profilens favoriter. Returnerar om den är favorit efteråt
    /// (alltid `false` i barnläge och utan aktiv profil).
    @discardableResult
    func toggleFavoriteChannel(_ groupID: String) -> Bool {
        guard !kidsRestricted, let personal = activeProfile?.personal else { return false }
        let isFavorite = personal.toggleFavoriteChannel(groupID)
        personalRevision += 1
        return isFavorite
    }

    /// Noterar att kanalgruppen setts (Senast sedda). Ingen effekt i barnläge.
    func noteChannelWatched(_ groupID: String) {
        guard !kidsRestricted, let personal = activeProfile?.personal else { return }
        personal.noteChannelWatched(groupID)
        personalRevision += 1
    }
}

struct ShortEPGTarget: Sendable {
    let groupID: String
    let streamID: String
}

struct ShortEPGResult: Sendable {
    let target: ShortEPGTarget
    let value: NowNext?
    let succeeded: Bool
}
