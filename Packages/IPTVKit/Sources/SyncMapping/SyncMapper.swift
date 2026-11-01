import Foundation
import Core
import Personal
import PlaybackCore
import Sync

/// Ren mappning mellan lagringsformat (`SyncableState`) och synkposter. Tid injiceras via `now`.
///
/// Postnycklar (`SyncRecordID.recordName`): `profile/<uuid>`, `playlist/<uuid>`,
/// `progress/<profile>/<playlist>/<kind>/<providerID>[/<seriesProviderID>]`, `watchlist/<profile>/<kind>/<providerID>`,
/// `rating/…`, `channelFavorite/<profile>/<groupID>`, `settings/<profile>`,
/// `subtitleOffset/<profile>/<playlist>/<kind>/<providerID>`. Fria textdelar kodas (`%`->`%25`, `/`->`%2F`).
///
/// Regler:
/// - `apply` kör `SyncMerge` mellan lokalt härledd post och fjärrposten och skriver tillbaka vinnaren med
///   fjärrens `updatedAt` (aldrig `now`). Den skapar inga lokala ändringar att pusha, utom `SyncChangeSet.dirty`.
/// - En profilgravsten vinner alltid över profilposten och släpper alla barnposter (även nyare från offlineenhet).
///   Dyker en levande profil upp trots gravsten återbekräftas gravstenen med tidsstämpel efter den (kommer med i `dirty`).
/// - Kapacitet tillämpas deterministiskt (tidsstämpel, nyckel). Min lista/betyg: utträngd post får gravsten med
///   `tidsstämpel + 1 s` (identiskt på alla enheter; rapporteras i `dirty`). Framsteg: bara lokal utträngning.
public enum SyncMapper {
    static let evictionOffset: TimeInterval = 1

    // MARK: Nycklar

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
    }
    static func unesc(_ s: String) -> String {
        s.replacingOccurrences(of: "%2F", with: "/").replacingOccurrences(of: "%25", with: "%")
    }

    public static func profileID(_ id: UUID) -> SyncRecordID { SyncRecordID(kind: .profile, key: id.uuidString) }
    public static func playlistID(_ id: UUID) -> SyncRecordID { SyncRecordID(kind: .playlist, key: id.uuidString) }
    public static func settingsID(_ profile: UUID) -> SyncRecordID { SyncRecordID(kind: .playbackSettings, key: profile.uuidString) }
    public static func progressID(profile: UUID, key k: ProgressKey) -> SyncRecordID {
        var key = "\(profile.uuidString)/\(k.playlistID.uuidString)/\(k.kind.rawValue)/\(esc(k.providerID))"
        if let s = k.seriesProviderID { key += "/\(esc(s))" }
        return SyncRecordID(kind: .progress, key: key)
    }
    public static func watchlistID(profile: UUID, item: ItemRef) -> SyncRecordID {
        SyncRecordID(kind: .watchlistItem, key: "\(profile.uuidString)/\(item.kind.rawValue)/\(esc(item.providerID))")
    }
    public static func ratingID(profile: UUID, item: ItemRef) -> SyncRecordID {
        SyncRecordID(kind: .rating, key: "\(profile.uuidString)/\(item.kind.rawValue)/\(esc(item.providerID))")
    }
    public static func favoriteID(profile: UUID, groupID: String) -> SyncRecordID {
        SyncRecordID(kind: .channelFavorite, key: "\(profile.uuidString)/\(esc(groupID))")
    }
    public static func subtitleOffsetID(_ k: SubtitleOffsetKey) -> SyncRecordID {
        SyncRecordID(kind: .subtitleOffset,
                     key: "\(k.profileID.uuidString)/\(k.playlistID.uuidString)/\(k.kind.rawValue)/\(esc(k.providerID))")
    }

    /// Profil som en barnpost tillhör (nil för profil-/spellistposter eller ogiltig nyckel).
    static func profileOf(_ id: SyncRecordID) -> UUID? {
        switch id.kind {
        case .profile, .playlist: return nil
        default: return UUID(uuidString: String(id.key.split(separator: "/", omittingEmptySubsequences: false).first ?? ""))
        }
    }

    private static func parts(_ id: SyncRecordID) -> [String] {
        id.key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    private static func parseProgress(_ id: SyncRecordID) -> (UUID, ProgressKey)? {
        let p = parts(id)
        guard p.count == 4 || p.count == 5, let prof = UUID(uuidString: p[0]), let pl = UUID(uuidString: p[1]),
              let kind = ContentKind(rawValue: p[2]) else { return nil }
        return (prof, ProgressKey(playlistID: pl, kind: kind, providerID: unesc(p[3]), seriesProviderID: p.count == 5 ? unesc(p[4]) : nil))
    }

    private static func parseItem(_ id: SyncRecordID) -> (UUID, ItemRef)? {
        let p = parts(id)
        guard p.count == 3, let prof = UUID(uuidString: p[0]), let kind = ContentKind(rawValue: p[1]) else { return nil }
        return (prof, ItemRef(kind: kind, providerID: unesc(p[2])))
    }

    private static func parseOffset(_ id: SyncRecordID) -> SubtitleOffsetKey? {
        let p = parts(id)
        guard p.count == 4, let prof = UUID(uuidString: p[0]), let pl = UUID(uuidString: p[1]),
              let kind = ContentKind(rawValue: p[2]) else { return nil }
        return SubtitleOffsetKey(profileID: prof, playlistID: pl, kind: kind, providerID: unesc(p[3]))
    }

    // MARK: Payloads

    private struct ProfilePayload: Codable {
        var playlistID: UUID
        var name: String
        var avatar: String
        var isKids: Bool
        var hasPin: Bool
        var createdAt: Date
    }
    private struct PlaylistPayload: Codable {
        var name: String
        var kind: PlaylistSourceKind
        var createdAt: Date
    }
    private struct RatingPayload: Codable { var rating: Rating }
    private struct OffsetPayload: Codable { var offsetMs: Int }
    private struct Marker: Codable { var v = 1 }

    private static func encode<T: Encodable>(_ v: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return (try? e.encode(v)) ?? Data()
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(T.self, from: data)
    }

    // MARK: Tillstånd -> poster

    private static func origin(_ id: SyncRecordID, at: Date, in s: SyncableState) -> String {
        if let o = s.origins[id], o.updatedAt == at { return o.origin }
        return s.deviceID
    }

    private static func make(_ id: SyncRecordID, payload: Data?, at: Date, deleted: Bool, in s: SyncableState) -> SyncRecord {
        SyncRecord(id: id, payload: payload, updatedAt: at, deleted: deleted, origin: origin(id, at: at, in: s))
    }

    private static func tombstone(_ id: SyncRecordID, at: Date, in s: SyncableState) -> SyncRecord {
        make(id, payload: nil, at: at, deleted: true, in: s)
    }

    /// Den lokala posten för ett id (levande eller gravsten), eller nil.
    static func localRecord(_ id: SyncRecordID, in s: SyncableState) -> SyncRecord? {
        switch id.kind {
        case .profile:
            guard let u = UUID(uuidString: id.key) else { return nil }
            if let p = s.profiles[u] {
                let payload = encode(ProfilePayload(playlistID: p.playlistID, name: p.name, avatar: p.avatar,
                                                    isKids: p.isKids, hasPin: p.hasPin, createdAt: p.createdAt))
                return make(id, payload: payload, at: p.updatedAt, deleted: false, in: s)
            }
            return s.deletedProfiles[u].map { tombstone(id, at: $0, in: s) }
        case .playlist:
            guard let u = UUID(uuidString: id.key) else { return nil }
            if let m = s.playlists[u] {
                let payload = encode(PlaylistPayload(name: m.name, kind: m.kind, createdAt: m.createdAt))
                return make(id, payload: payload, at: m.updatedAt, deleted: false, in: s)
            }
            return s.deletedPlaylists[u].map { tombstone(id, at: $0, in: s) }
        default:
            break
        }
        guard let prof = profileOf(id) else { return nil }
        if s.deletedProfiles[prof] != nil { return s.childTombstones[id].map { tombstone(id, at: $0, in: s) } }
        let child = s.childTombstones[id].map { tombstone(id, at: $0, in: s) }
        switch id.kind {
        case .progress:
            guard let (_, k) = parseProgress(id), let w = s.progress[prof]?[k] else { return child }
            var position = w.position
            if !position.isFinite { position = 0 }
            var duration = w.duration
            if let d = duration, !(d.isFinite && d > 0) { duration = nil }
            let payload = SyncProgressPayload(position: position, duration: duration, watched: w.watched).encoded()
            return make(id, payload: payload, at: w.updatedAt, deleted: false, in: s)
        case .watchlistItem:
            guard let (_, item) = parseItem(id), let e = s.personal[prof]?.watchlist.first(where: { $0.item == item }) else { return child }
            if let removed = e.removedAt { return tombstone(id, at: removed, in: s) }
            return make(id, payload: encode(Marker()), at: e.addedAt, deleted: false, in: s)
        case .rating:
            guard let (_, item) = parseItem(id), let e = s.personal[prof]?.ratingEntries.first(where: { $0.item == item }) else { return child }
            guard let r = e.rating else { return tombstone(id, at: e.updatedAt, in: s) }
            return make(id, payload: encode(RatingPayload(rating: r)), at: e.updatedAt, deleted: false, in: s)
        case .channelFavorite:
            let p = parts(id)
            guard p.count == 2, let e = s.personal[prof]?.favoriteEntries.first(where: { $0.id == unesc(p[1]) }) else { return child }
            if let removed = e.removedAt { return tombstone(id, at: removed, in: s) }
            return make(id, payload: encode(Marker()), at: e.updatedAt, deleted: false, in: s)
        case .playbackSettings:
            guard var st = s.settings[prof] else { return child }
            let at = st.updatedAt
            st.updatedAt = .distantPast // kanonisk payload; tidsstämpeln bärs av posten
            return make(id, payload: encode(st), at: at, deleted: false, in: s)
        case .subtitleOffset:
            guard let k = parseOffset(id), let o = s.subtitleOffsets[k] else { return child }
            return make(id, payload: encode(OffsetPayload(offsetMs: o.offsetMs)), at: o.updatedAt, deleted: false, in: s)
        case .profile, .playlist:
            return nil
        }
    }

    /// Alla ids tillståndet har någon post för.
    static func recordIDs(in s: SyncableState) -> Set<SyncRecordID> {
        var ids = Set<SyncRecordID>()
        for u in s.profiles.keys { ids.insert(profileID(u)) }
        for u in s.deletedProfiles.keys { ids.insert(profileID(u)) }
        for u in s.playlists.keys { ids.insert(playlistID(u)) }
        for u in s.deletedPlaylists.keys { ids.insert(playlistID(u)) }
        for (prof, snap) in s.personal {
            for e in snap.watchlist { ids.insert(watchlistID(profile: prof, item: e.item)) }
            for e in snap.ratingEntries { ids.insert(ratingID(profile: prof, item: e.item)) }
            for e in snap.favoriteEntries { ids.insert(favoriteID(profile: prof, groupID: e.id)) }
        }
        for (prof, map) in s.progress { for k in map.keys { ids.insert(progressID(profile: prof, key: k)) } }
        for u in s.settings.keys { ids.insert(settingsID(u)) }
        for k in s.subtitleOffsets.keys { ids.insert(subtitleOffsetID(k)) }
        for id in s.childTombstones.keys { ids.insert(id) }
        return ids
    }

    /// Ids för alla barnposter (i dag) till en profil, inklusive redan kända gravstenar.
    static func childRecordIDs(of profile: UUID, in s: SyncableState) -> Set<SyncRecordID> {
        recordIDs(in: s).filter { profileOf($0) == profile }
            .union([settingsID(profile)])
    }

    /// Poster att pusha: alla (`dirty == nil`) eller bara de angivna ids. Sorterade (deterministisk ordning).
    /// Barn till raderade profiler tas bara med som gravstenar.
    public static func records(from state: SyncableState, dirty: Set<SyncRecordID>? = nil) -> [SyncRecord] {
        let ids = dirty ?? recordIDs(in: state)
        return ids.compactMap { localRecord($0, in: state) }
            .sorted { ($0.id.kind.rawValue, $0.id.key) < ($1.id.kind.rawValue, $1.id.key) }
    }

    /// Ids vars poster skiljer sig mellan två tillstånd (för att markera lokala ändringar som smutsiga).
    public static func changedIDs(from old: SyncableState, to new: SyncableState) -> Set<SyncRecordID> {
        var changed = Set<SyncRecordID>()
        for id in recordIDs(in: old).union(recordIDs(in: new)) where localRecord(id, in: old) != localRecord(id, in: new) {
            changed.insert(id)
        }
        return changed
    }

    /// Kanonisk, ursprungsfri vy (jämlikhet mellan enheter). Bokföringsgravstenar utelämnas.
    static func canonical(_ s: SyncableState) -> [SyncRecord] {
        var base = s
        base.childTombstones = [:]
        return records(from: base).map { r in
            var r = r
            r.origin = ""
            // Profil-/spellistgravstenar betyder bara "raderad"; tidsstämpeln kan skilja mellan enheter
            // (molnet behåller max) utan att det spelar någon roll.
            if r.deleted, r.id.kind == .profile || r.id.kind == .playlist { r.updatedAt = .distantPast }
            return r
        }
    }

    // MARK: Poster -> tillstånd

    private static func rank(_ k: SyncKind) -> Int {
        switch k {
        case .playlist: return 0
        case .profile: return 1
        default: return 2
        }
    }

    @discardableResult
    public static func apply(_ records: [SyncRecord], to state: inout SyncableState, now: Date) -> SyncChangeSet {
        var cs = SyncChangeSet()
        // Playlist- och profilposter först, så att gravstenar hinner släppa barnposter.
        let ordered = records.enumerated().sorted { (rank($0.element.id.kind), $0.offset) < (rank($1.element.id.kind), $1.offset) }
        for (_, r) in ordered { applyOne(r, to: &state, now: now, cs: &cs) }
        for p in cs.progress.union(cs.personal) {
            cs.dirty.formUnion(normalize(&state, profile: p, now: now))
        }
        return cs
    }

    private static func clampedTime(_ d: Date, now: Date) -> Date {
        min(d, now.addingTimeInterval(SyncMerge.maxFuture))
    }

    private static func applyOne(_ r: SyncRecord, to s: inout SyncableState, now: Date, cs: inout SyncChangeSet) {
        switch r.id.kind {
        case .profile:
            guard let u = UUID(uuidString: r.id.key) else { return }
            if r.deleted {
                tombstoneProfile(u, at: clampedTime(r.updatedAt, now: now), origin: r.origin, in: &s, cs: &cs)
                return
            }
            if let t = s.deletedProfiles[u] {
                reassertProfile(u, deletedAt: t, against: r, in: &s, cs: &cs, now: now)
                return
            }
            if let payload = decode(ProfilePayload.self, r.payload), let pt = s.deletedPlaylists[payload.playlistID] {
                // Profil i en raderad spellista.
                s.deletedProfiles[u] = pt
                cs.dirty.insert(profileID(u))
                if s.profiles[u] != nil { tombstoneProfile(u, at: pt, origin: s.deviceID, in: &s, cs: &cs) }
                return
            }
        case .playlist:
            guard let u = UUID(uuidString: r.id.key) else { return }
            if r.deleted {
                tombstonePlaylist(u, at: clampedTime(r.updatedAt, now: now), origin: r.origin, in: &s, cs: &cs)
                return
            }
            if let t = s.deletedPlaylists[u] {
                let ts = max(t, clampedTime(r.updatedAt, now: now).addingTimeInterval(evictionOffset))
                if ts != t { s.deletedPlaylists[u] = ts; s.origins[playlistID(u)] = nil }
                cs.dirty.insert(playlistID(u))
                return
            }
        default:
            guard let prof = profileOf(r.id) else { return }
            if s.deletedProfiles[prof] != nil { cs.droppedOrphans += 1; return }
        }

        let local = localRecord(r.id, in: s)
        let merged = SyncMerge.merge(local: local, remote: r, now: now)
        if merged == local { return }
        store(merged, in: &s, cs: &cs)
    }

    private static func reassertProfile(_ u: UUID, deletedAt t: Date, against r: SyncRecord, in s: inout SyncableState,
                                        cs: inout SyncChangeSet, now: Date) {
        let ts = max(t, clampedTime(r.updatedAt, now: now).addingTimeInterval(evictionOffset))
        if ts != t { s.deletedProfiles[u] = ts }
        cs.dirty.insert(profileID(u))
    }

    private static func tombstoneProfile(_ u: UUID, at ts: Date, origin: String, in s: inout SyncableState, cs: inout SyncChangeSet) {
        let existing = s.deletedProfiles[u]
        let at = max(existing ?? ts, ts)
        s.deletedProfiles[u] = at
        if existing != at { s.origins[profileID(u)] = .init(origin: origin, updatedAt: at) }
        let had = s.profiles[u] != nil || s.personal[u] != nil || s.progress[u] != nil || s.settings[u] != nil
            || s.subtitleOffsets.keys.contains { $0.profileID == u }
        if had {
            s.removeProfileData(u)
            cs.removedProfiles.insert(u)
            cs.profiles.insert(u)
        } else if existing == nil {
            cs.removedProfiles.insert(u)
        }
    }

    private static func tombstonePlaylist(_ u: UUID, at ts: Date, origin: String, in s: inout SyncableState, cs: inout SyncChangeSet) {
        let existing = s.deletedPlaylists[u]
        let at = max(existing ?? ts, ts)
        s.deletedPlaylists[u] = at
        if existing != at { s.origins[playlistID(u)] = .init(origin: origin, updatedAt: at) }
        if s.playlists.removeValue(forKey: u) != nil || existing == nil {
            cs.playlists.insert(u)
            cs.removedPlaylists.insert(u)
        }
        for p in s.profiles.values where p.playlistID == u {
            tombstoneProfile(p.id, at: at, origin: origin, in: &s, cs: &cs)
        }
    }

    private static func noteOrigin(_ r: SyncRecord, in s: inout SyncableState) {
        if r.origin == s.deviceID { s.origins[r.id] = nil } else { s.origins[r.id] = .init(origin: r.origin, updatedAt: r.updatedAt) }
    }

    /// Skriver vinnande post till tillståndet. `merged` är redan sammanslagen; `updatedAt` är fjärrens (aldrig `now`).
    private static func store(_ r: SyncRecord, in s: inout SyncableState, cs: inout SyncChangeSet) {
        noteOrigin(r, in: &s)
        switch r.id.kind {
        case .profile:
            guard let u = UUID(uuidString: r.id.key), !r.deleted, let p = decode(ProfilePayload.self, r.payload) else { return }
            s.profiles[u] = Profile(id: u, playlistID: p.playlistID, name: p.name, avatar: p.avatar, isKids: p.isKids,
                                    hasPin: p.hasPin, createdAt: p.createdAt, updatedAt: r.updatedAt)
            cs.profiles.insert(u)
        case .playlist:
            guard let u = UUID(uuidString: r.id.key), !r.deleted, let p = decode(PlaylistPayload.self, r.payload) else { return }
            s.playlists[u] = PlaylistMeta(name: p.name, kind: p.kind, createdAt: p.createdAt, updatedAt: r.updatedAt)
            cs.playlists.insert(u)
        case .progress:
            guard let (prof, k) = parseProgress(r.id) else { return }
            if r.deleted {
                if s.progress[prof]?.removeValue(forKey: k) != nil { cs.progress.insert(prof) }
                s.childTombstones[r.id] = nil
                return
            }
            guard let p = decode(SyncProgressPayload.self, r.payload) else { return }
            s.progress[prof, default: [:]][k] = WatchProgress(key: k, position: p.position, duration: p.duration,
                                                              watched: p.watched, updatedAt: r.updatedAt)
            s.childTombstones[r.id] = nil
            cs.progress.insert(prof)
        case .watchlistItem:
            guard let (prof, item) = parseItem(r.id) else { return }
            var snap = s.personal[prof] ?? PersonalSnapshot()
            let prior = snap.watchlist.first { $0.item == item }
            snap.watchlist.removeAll { $0.item == item }
            if r.deleted {
                snap.watchlist.append(WatchlistEntry(item: item, addedAt: min(prior?.addedAt ?? r.updatedAt, r.updatedAt), removedAt: r.updatedAt))
            } else {
                snap.watchlist.append(WatchlistEntry(item: item, addedAt: r.updatedAt))
            }
            s.personal[prof] = snap
            cs.personal.insert(prof)
        case .rating:
            guard let (prof, item) = parseItem(r.id) else { return }
            var snap = s.personal[prof] ?? PersonalSnapshot()
            snap.ratingEntries.removeAll { $0.item == item }
            let rating = r.deleted ? nil : decode(RatingPayload.self, r.payload)?.rating
            if !r.deleted && rating == nil { return }
            snap.ratingEntries.append(RatingEntry(item: item, rating: rating, updatedAt: r.updatedAt))
            s.personal[prof] = snap
            cs.personal.insert(prof)
        case .channelFavorite:
            let p = parts(r.id)
            guard p.count == 2, let prof = UUID(uuidString: p[0]) else { return }
            let gid = unesc(p[1])
            var snap = s.personal[prof] ?? PersonalSnapshot()
            snap.favoriteEntries.removeAll { $0.id == gid }
            snap.favoriteEntries.append(FavoriteChannelEntry(id: gid, updatedAt: r.updatedAt, removedAt: r.deleted ? r.updatedAt : nil))
            s.personal[prof] = snap
            cs.personal.insert(prof)
        case .playbackSettings:
            guard let prof = UUID(uuidString: r.id.key) else { return }
            if r.deleted { s.settings[prof] = nil; cs.settings.insert(prof); return }
            guard var st = decode(PlaybackSettings.self, r.payload) else { return }
            st.updatedAt = r.updatedAt
            s.settings[prof] = st
            cs.settings.insert(prof)
        case .subtitleOffset:
            guard let k = parseOffset(r.id) else { return }
            if r.deleted { s.subtitleOffsets[k] = nil } else {
                guard let o = decode(OffsetPayload.self, r.payload) else { return }
                s.subtitleOffsets[k] = SubtitleOffset(offsetMs: o.offsetMs, updatedAt: r.updatedAt)
            }
            cs.subtitleOffsets.insert(k.profileID)
        }
    }

    // MARK: Kapacitet

    /// Tillämpar kapaciteterna för en profil deterministiskt. Utträngd post får gravsten (`tidsstämpel + 1 s`).
    /// Returnerar ids som enheten själv måste pusha. Anropas av `apply` och av koordinatorn efter lokala ändringar.
    @discardableResult
    public static func normalize(_ s: inout SyncableState, profile prof: UUID, now: Date) -> Set<SyncRecordID> {
        var evicted = Set<SyncRecordID>()
        let caps = s.capacities

        // Framsteg trängs bara ut lokalt (ingen gravsten): en gravsten mellan två framstegsposter gör
        // `SyncMerge` icke-associativ. Utan gravsten konvergerar det ändå: alla enheter ser till slut samma
        // uppsättning poster, tidsstämplarna växer bara, så de utträngda ligger kvar under toppen.
        if var map = s.progress[prof], map.count > caps.progress {
            let drop = map.values.sorted { ($0.updatedAt, $0.key.sortKey) < ($1.updatedAt, $1.key.sortKey) }
                .prefix(map.count - caps.progress)
            for w in drop {
                map[w.key] = nil
                s.origins[progressID(profile: prof, key: w.key)] = nil
            }
            s.progress[prof] = map
        }

        if var snap = s.personal[prof] {
            let liveW = snap.watchlist.filter(\.isLive)
            if liveW.count > caps.watchlist {
                let drop = liveW.sorted { ($0.addedAt, itemKey($0.item)) < ($1.addedAt, itemKey($1.item)) }
                    .prefix(liveW.count - caps.watchlist)
                for e in drop {
                    guard let i = snap.watchlist.firstIndex(where: { $0.item == e.item }) else { continue }
                    snap.watchlist[i].removedAt = e.addedAt.addingTimeInterval(evictionOffset)
                    let id = watchlistID(profile: prof, item: e.item)
                    s.origins[id] = nil
                    evicted.insert(id)
                }
            }
            let liveR = snap.ratingEntries.filter(\.isLive)
            if liveR.count > caps.ratings {
                let drop = liveR.sorted { ($0.updatedAt, itemKey($0.item)) < ($1.updatedAt, itemKey($1.item)) }
                    .prefix(liveR.count - caps.ratings)
                for e in drop {
                    guard let i = snap.ratingEntries.firstIndex(where: { $0.item == e.item }) else { continue }
                    snap.ratingEntries[i].rating = nil
                    snap.ratingEntries[i].updatedAt = e.updatedAt.addingTimeInterval(evictionOffset)
                    let id = ratingID(profile: prof, item: e.item)
                    s.origins[id] = nil
                    evicted.insert(id)
                }
            }
            s.personal[prof] = snap
        }
        return evicted
    }

    private static func itemKey(_ i: ItemRef) -> String { "\(i.kind.rawValue)|\(i.providerID)" }
}

private extension ProgressKey {
    var sortKey: String { "\(playlistID.uuidString)|\(kind.rawValue)|\(providerID)|\(seriesProviderID ?? "")" }
}

public extension SyncRecordID {
    /// Postnamn som i planen, t.ex. `profile/<uuid>`.
    var recordName: String {
        let prefix: String
        switch kind {
        case .profile: prefix = "profile"
        case .playlist: prefix = "playlist"
        case .progress: prefix = "progress"
        case .watchlistItem: prefix = "watchlist"
        case .rating: prefix = "rating"
        case .channelFavorite: prefix = "channelFavorite"
        case .playbackSettings: prefix = "settings"
        case .subtitleOffset: prefix = "subtitleOffset"
        }
        return "\(prefix)/\(key)"
    }
}
