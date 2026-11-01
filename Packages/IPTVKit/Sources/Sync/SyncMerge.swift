import Foundation

/// Sammanslagning av synkposter. Ren funktion, tid injiceras via `now`.
///
/// Regler:
/// - Båda posternas `updatedAt` klampas till `now + 1 dygn` (symmetri => kommutativ).
/// - Total ordning: senare `updatedAt` vinner; lika => lägre `origin`; lika => lägre
///   payload-bytes (lexikografiskt, nil först); lika => levande post före gravsten.
///   Gravsten har alltså ingen särställning vid lika tid utöver ordningen ovan.
/// - Förlorarens payload blandas aldrig in, utom för `.progress` (båda levande):
///   position = max, watched = OR, duration från vinnaren (annars den andra).
///   Begränsning: med en gravsten mellan två progress-poster är sammanslagningen
///   inte strikt associativ (äldre positionen kan överleva i en gruppering men inte i en annan).
public enum SyncMerge {
    public static let maxFuture: TimeInterval = 86_400

    public static func merge(local: SyncRecord?, remote: SyncRecord, now: Date) -> SyncRecord {
        let r = clamped(remote, now: now)
        guard let local else { return r }
        let l = clamped(local, now: now)

        if l.id.kind == .progress, !l.deleted, !r.deleted,
           let merged = mergeProgress(l, r) {
            return merged
        }
        return wins(l, over: r) ? l : r
    }

    private static func clamped(_ record: SyncRecord, now: Date) -> SyncRecord {
        var copy = record
        let limit = now.addingTimeInterval(maxFuture)
        if copy.updatedAt > limit { copy.updatedAt = limit }
        return copy
    }

    /// Total ordning: true om a ska vinna över b.
    private static func wins(_ a: SyncRecord, over b: SyncRecord) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.origin != b.origin { return a.origin < b.origin }
        if a.payload != b.payload {
            switch (a.payload, b.payload) {
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x.lexicographicallyPrecedes(y)
            }
        }
        if a.deleted != b.deleted { return !a.deleted }
        return true
    }

    private static func mergeProgress(_ a: SyncRecord, _ b: SyncRecord) -> SyncRecord? {
        let decoder = JSONDecoder()
        guard let pa = a.payload.flatMap({ try? decoder.decode(SyncProgressPayload.self, from: $0) }),
              let pb = b.payload.flatMap({ try? decoder.decode(SyncProgressPayload.self, from: $0) })
        else { return nil }

        // Metadata följer (updatedAt, origin); övriga fält är max/OR och därmed
        // oberoende av gruppering.
        let aFirst: Bool
        if a.updatedAt != b.updatedAt { aFirst = a.updatedAt > b.updatedAt }
        else { aFirst = a.origin <= b.origin }
        let win = aFirst ? a : b

        let durations = [pa.duration, pb.duration].compactMap { $0 }
        let merged = SyncProgressPayload(
            position: max(pa.position, pb.position),
            duration: durations.max(),
            watched: pa.watched || pb.watched
        )
        // Slås inget ihop (resultatet är semantiskt en av posterna med vinnarens metadata)
        // returneras den posten byte-identiskt => merge(x, x) == x. Vid lika
        // metadata väljs lägre payload-bytes för kommutativitet.
        let candidates = [(a, pa), (b, pb)]
            .filter { $0.0.updatedAt == win.updatedAt && $0.0.origin == win.origin && $0.1 == merged }
            .map { $0.0 }
            .sorted { ($0.payload ?? Data()).lexicographicallyPrecedes($1.payload ?? Data()) }
        if let same = candidates.first { return same }
        var result = win
        result.payload = merged.encoded()
        return result
    }
}
