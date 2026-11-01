import Core
import Foundation
import Library
import Personal
import PlaybackCore
import Sync
import SyncMapping

/// Fasaden mellan synken och de riktiga lagren. Läser hela det synkbara tillståndet (`SyncableState`) ur
/// profillagret, profilernas nycklar i UserDefaults, undertextförskjutningarna och spellistmetadata, och skriver
/// resultatet av en `SyncMapper.apply` tillbaka med fjärrens tidsstämplar (aldrig "nu").
///
/// Det som måste överleva en omstart ligger i en enda JSON-post (`sync.bridge.v1`): gravstenarna för profiler,
/// spellistor och barnposter, ursprung, vilka profiler som saknar lokal PIN-hash och förskjutningar som väntar på
/// sin spellista. Utan gravstenarna kunde en raderad profil återuppstå.
///
/// Äldre poster (utan riktig tidsstämpel) får en stabil ersättning (`createdAt`) bara när tillståndet byggs för
/// synk; lokala data skrivs aldrig om. Lokal städning skapar aldrig gravstenar.
@MainActor
final class SyncStoreBridge {
    /// Krokar som `AppModel` sätter för att synken ska nå levande objekt (sessioner, nedladdningar, vyer).
    struct Hooks {
        /// Sessionens lager för profilen, om en session finns (annars skapas ett tillfälligt på samma nyckel).
        var personalStore: (UUID) -> UserDefaultsPersonalStore? = { _ in nil }
        var progressStore: (UUID) -> UserDefaultsUserStateStore? = { _ in nil }
        /// Ger inställningar till en levande session. Sant om en session tog emot (och sparade) dem.
        var applySettings: (UUID, PlaybackSettings) -> Bool = { _, _ in false }
        /// Tar bort en profil som raderats på en annan enhet. Utan krok tar bryggan själv bort lagren.
        var removeProfile: ((UUID) -> Void)?
        /// En profil från synken har sparats (sessionen och vyerna uppdateras).
        var profileApplied: (Profile) -> Void = { _ in }
        /// Efter att ett helt `SyncChangeSet` skrivits.
        var didApply: (SyncChangeSet) -> Void = { _ in }
    }

    static let stateKey = "sync.bridge.v1"

    /// Förskjutning som inte kunnat sparas ännu (spellistan saknas i databasen).
    struct PendingOffset: Codable, Equatable {
        var profileID: UUID
        var playlistID: UUID
        var kind: ContentKind
        var providerID: String
        var offsetMs: Int
        var updatedAt: Date

        var key: SubtitleOffsetKey {
            SubtitleOffsetKey(profileID: profileID, playlistID: playlistID, kind: kind, providerID: providerID)
        }
    }

    private struct Persisted: Codable {
        var bookkeeping = SyncBookkeeping()
        /// Profiler där fjärrposten har PIN men enheten saknar PIN-hash (se `writeBack`).
        var pinMissing: [UUID] = []
        var pendingOffsets: [PendingOffset] = []
    }

    var hooks = Hooks()
    let deviceID: String
    private let defaults: UserDefaults
    private let profiles: any ProfileStore
    private let pins: any ProfilePinStore
    private let metadata: PlaylistMetadataStore
    private let subtitles: SubtitleStore?
    private var persisted: Persisted

    init(deviceID: String, defaults: UserDefaults, profiles: any ProfileStore, pins: any ProfilePinStore,
         metadata: PlaylistMetadataStore, subtitles: SubtitleStore?) {
        self.deviceID = deviceID
        self.defaults = defaults
        self.profiles = profiles
        self.pins = pins
        self.metadata = metadata
        self.subtitles = subtitles
        if let data = defaults.data(forKey: Self.stateKey),
           let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            persisted = saved
        } else {
            persisted = Persisted()
        }
    }

    // MARK: Tillstånd ur lagren

    /// Tidsstämplar före 1970 (gamla blobbar: `distantPast`) och epok 0 (gamla databasrader) räknas som saknade.
    private static func isLegacy(_ date: Date) -> Bool { date <= Date(timeIntervalSince1970: 0) }

    /// Ersättning för en saknad tidsstämpel: `fallback` plus ett litet index, så att ordningen bevaras.
    private static func stamp(_ date: Date, fallback: Date) -> Date {
        guard isLegacy(date) else { return date }
        let index = date.timeIntervalSince(.distantPast)
        return fallback.addingTimeInterval(index >= 0 && index < 100_000 ? index * 0.001 : 0)
    }

    private func personalStore(_ id: UUID) -> UserDefaultsPersonalStore {
        hooks.personalStore(id) ?? UserDefaultsPersonalStore(defaults: defaults, key: ProfileKeys.personal(id))
    }

    private func progressStore(_ id: UUID) -> UserDefaultsUserStateStore {
        hooks.progressStore(id) ?? UserDefaultsUserStateStore(defaults: defaults, key: ProfileKeys.progress(id))
    }

    /// Bygger det synkbara tillståndet ur lagren. Skriver ingenting.
    func loadState() -> SyncableState {
        var state = SyncableState(deviceID: deviceID)
        state.bookkeeping = persisted.bookkeeping
        for entry in metadata.allIncludingTombstones() {
            if let deletedAt = entry.deletedAt {
                state.deletedPlaylists[entry.id] = max(state.deletedPlaylists[entry.id] ?? deletedAt, deletedAt)
            } else {
                let updated = Self.isLegacy(entry.updatedAt) ? entry.createdAt : entry.updatedAt
                state.playlists[entry.id] = PlaylistMeta(name: entry.name, kind: entry.kind,
                                                         createdAt: entry.createdAt, updatedAt: updated)
            }
        }
        for var profile in profiles.allProfiles() where state.deletedProfiles[profile.id] == nil {
            if Self.isLegacy(profile.updatedAt) { profile.updatedAt = profile.createdAt }
            // En profil vars PIN-hash saknas här är ändå "med PIN" för de andra enheterna (annars skulle vi
            // skicka tillbaka hasPin = false och ta bort deras skydd).
            if persisted.pinMissing.contains(profile.id) { profile.hasPin = true }
            state.profiles[profile.id] = profile
        }
        for profile in state.profiles.values { loadChildren(of: profile, into: &state) }
        return state
    }

    private func loadChildren(of profile: Profile, into state: inout SyncableState) {
        let id = profile.id
        let fallback = profile.createdAt

        var snapshot = personalStore(id).syncSnapshot()
        for i in snapshot.watchlist.indices {
            snapshot.watchlist[i].addedAt = Self.stamp(snapshot.watchlist[i].addedAt, fallback: fallback)
        }
        for i in snapshot.ratingEntries.indices {
            snapshot.ratingEntries[i].updatedAt = Self.stamp(snapshot.ratingEntries[i].updatedAt, fallback: fallback)
        }
        for i in snapshot.favoriteEntries.indices {
            snapshot.favoriteEntries[i].updatedAt = Self.stamp(snapshot.favoriteEntries[i].updatedAt, fallback: fallback)
        }
        state.personal[id] = snapshot

        let entries = progressStore(id).allEntries()
        if !entries.isEmpty {
            state.progress[id] = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        }

        let settingsKey = ProfileKeys.settings(id)
        if defaults.data(forKey: settingsKey) != nil {
            var settings = PlaybackSettings.load(from: defaults, key: settingsKey)
            var include = true
            if Self.isLegacy(settings.updatedAt) {
                // Orörda standardinställningar skickas aldrig (de skulle skriva över nyare fjärrdata).
                var untouched = settings
                untouched.updatedAt = .distantPast
                if untouched == PlaybackSettings() { include = false } else { settings.updatedAt = fallback }
            }
            if include { state.settings[id] = settings }
        }

        if let subtitles, let offsets = try? subtitles.offsets(profileID: id) {
            for offset in offsets {
                let key = SubtitleOffsetKey(profileID: id, playlistID: offset.key.playlistID,
                                            kind: offset.key.kind, providerID: offset.key.providerID)
                state.subtitleOffsets[key] = SubtitleOffset(offsetMs: offset.offsetMs,
                                                            updatedAt: Self.stamp(offset.updatedAt, fallback: fallback))
            }
        }
    }

    // MARK: Lokala raderingar

    /// Noterar att användaren raderar en profil (anropas FÖRE att lagren töms). Returnerar posterna att pusha.
    func recordProfileDeletion(_ id: UUID, now: Date) -> Set<SyncRecordID> {
        // Redan noterad (t.ex. via spellistans borttagning): inget mer att göra, och ingen dyr inläsning.
        if persisted.bookkeeping.deletedProfiles.contains(where: { $0.id == id.uuidString }) { return [] }
        let old = loadState()
        guard old.deletedProfiles[id] == nil else { return [] }
        var new = old
        new.deleteProfile(id, now: now)
        persisted.bookkeeping = new.bookkeeping
        persisted.pinMissing.removeAll { $0 == id }
        persisted.pendingOffsets.removeAll { $0.profileID == id }
        save()
        return SyncMapper.changedIDs(from: old, to: new)
    }

    /// Noterar att användaren tar bort en spellista (anropas FÖRE att metadata och profiler töms). Profilerna får
    /// gravstenar. Returnerar posterna att pusha.
    func recordPlaylistDeletion(_ id: UUID, now: Date) -> Set<SyncRecordID> {
        let old = loadState()
        guard old.deletedPlaylists[id] == nil else { return [] }
        var new = old
        new.deletePlaylist(id, now: now)
        persisted.bookkeeping = new.bookkeeping
        let gone = Set(old.profiles.values.filter { $0.playlistID == id }.map(\.id))
        persisted.pinMissing.removeAll { gone.contains($0) }
        persisted.pendingOffsets.removeAll { gone.contains($0.profileID) || $0.playlistID == id }
        save()
        return SyncMapper.changedIDs(from: old, to: new)
    }

    /// Profilen är PIN-skyddad på andra enheter men saknar PIN-hash här (se `writeBack`).
    func needsPin(_ id: UUID) -> Bool { persisted.pinMissing.contains(id) }

    /// Hävs låset: PIN-hashen finns nu lokalt (Task 7 MÅSTE anropa denna då). Profilen får `hasPin = true`
    /// lokalt (fjärrens `updatedAt` behålls). Det enda sättet att häva låset lokalt; fjärr-`hasPin == false`
    /// hävs i `writeBack`.
    func clearPinMissing(_ id: UUID) {
        guard persisted.pinMissing.contains(id) else { return }
        persisted.pinMissing.removeAll { $0 == id }
        save()
        if var profile = profiles.allProfiles().first(where: { $0.id == id }), !profile.hasPin {
            profile.hasPin = true
            profiles.saveSynced(profile)
            hooks.profileApplied(profile)
        }
    }

    // MARK: Fjärrändringar till lagren

    /// Skriver det en `SyncMapper.apply` ändrade. `state` är tillståndet efter `apply`.
    func writeBack(_ state: SyncableState, changes cs: SyncChangeSet) {
        // 1. Spellistor först (förskjutningar behöver sin spellista).
        for id in cs.playlists.union(cs.removedPlaylists) {
            if let meta = state.playlists[id] {
                metadata.applyRemote(id: id, name: meta.name, kind: meta.kind, createdAt: meta.createdAt,
                                     updatedAt: meta.updatedAt)
            } else if let deletedAt = state.deletedPlaylists[id] {
                metadata.applyRemoteTombstone(id: id, deletedAt: deletedAt)
            }
        }

        // 2. Profiler.
        let before = Dictionary(profiles.allProfiles().map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for id in cs.removedProfiles { removeProfileLocally(id) }
        for id in cs.profiles {
            guard state.deletedProfiles[id] == nil, var profile = state.profiles[id] else { continue }
            if profile.hasPin {
                // PIN-hashen synkas inte (Keychain-synk är en egen uppgift). Hade enheten redan PIN för profilen
                // behålls den. Annars sparas profilen utan PIN-flagga lokalt (så att ingen kan låsas ute av en
                // kod som inte finns här) men märks, och synken fortsätter rapportera hasPin = true.
                if before[id]?.hasPin != true {
                    profile.hasPin = false
                    if !persisted.pinMissing.contains(id) { persisted.pinMissing.append(id) }
                }
            } else {
                persisted.pinMissing.removeAll { $0 == id }
            }
            profiles.saveSynced(profile)
            hooks.profileApplied(profile)
        }

        // 3. Min lista, betyg och favoriter.
        for id in cs.personal {
            guard state.deletedProfiles[id] == nil, let snapshot = state.personal[id] else { continue }
            personalStore(id).replaceSyncSnapshot(snapshot)
        }

        // 4. Tittarpositioner (fjärrens updatedAt behålls; lagret bumpar inget). Utträngning hanteras av lagret.
        for id in cs.progress {
            guard state.deletedProfiles[id] == nil, let map = state.progress[id] else { continue }
            let store = progressStore(id)
            for (key, value) in map where store.progress(for: key) != value { store.save(value) }
        }

        // 5. Inställningar.
        for id in cs.settings where state.deletedProfiles[id] == nil {
            if let settings = state.settings[id] {
                if !hooks.applySettings(id, settings) { settings.save(to: defaults, key: ProfileKeys.settings(id)) }
            } else {
                defaults.removeObject(forKey: ProfileKeys.settings(id))
            }
        }

        // 6. Förskjutningar sist: spellistan måste finnas i databasen, annars väntar de.
        for id in cs.subtitleOffsets where state.deletedProfiles[id] == nil {
            let incoming = state.subtitleOffsets.filter { $0.key.profileID == id }
            for (key, offset) in incoming {
                if applyOffset(key, offset) {
                    persisted.pendingOffsets.removeAll { $0.key == key }
                } else {
                    queue(key, offset)
                }
            }
        }
        for id in cs.removedProfiles { persisted.pendingOffsets.removeAll { $0.profileID == id } }

        // 7. Bokföring. Ursprung som inte längre gäller en befintlig post släpps (håller posten liten).
        var book = state.bookkeeping
        let current = Dictionary(SyncMapper.records(from: state).map { ($0.id, $0.updatedAt) },
                                 uniquingKeysWith: { $1 })
        book.origins = book.origins.filter { current[$0.id] == $0.at }
        persisted.bookkeeping = book
        save()
        hooks.didApply(cs)
    }

    /// Försöker spara förskjutningar som väntat på sin spellista (anropas efter varje hämtning och när en
    /// spellista kommit in i databasen).
    func retryPendingOffsets() {
        guard !persisted.pendingOffsets.isEmpty else { return }
        let deleted = persisted.bookkeeping.deletedPlaylists.compactMap { UUID(uuidString: $0.id) }
        var rest: [PendingOffset] = []
        for pending in persisted.pendingOffsets {
            if deleted.contains(pending.playlistID) { continue }
            if !applyOffset(pending.key, SubtitleOffset(offsetMs: pending.offsetMs, updatedAt: pending.updatedAt)) {
                rest.append(pending)
            }
        }
        if rest != persisted.pendingOffsets {
            persisted.pendingOffsets = rest
            save()
        }
    }

    var pendingOffsetCount: Int { persisted.pendingOffsets.count }

    /// Sant om förskjutningen är omhändertagen (sparad, eller lokalt lika ny eller nyare, eller inget lager).
    /// Falskt om den bör försökas igen (spellistan saknas i databasen, läsfel).
    private func applyOffset(_ key: SubtitleOffsetKey, _ offset: SubtitleOffset) -> Bool {
        guard let subtitles else { return true }
        let subtitleKey = SubtitleKey(profileID: key.profileID, playlistID: key.playlistID, kind: key.kind,
                                      providerID: key.providerID)
        do {
            let local = try subtitles.offsets(profileID: key.profileID).first { $0.key == subtitleKey }
            if let local, local.updatedAt >= offset.updatedAt { return true }
            return try subtitles.applyRemoteOffset(offset.offsetMs, key: subtitleKey, updatedAt: offset.updatedAt)
        } catch {
            return false
        }
    }

    private func queue(_ key: SubtitleOffsetKey, _ offset: SubtitleOffset) {
        persisted.pendingOffsets.removeAll { $0.key == key }
        persisted.pendingOffsets.append(PendingOffset(profileID: key.profileID, playlistID: key.playlistID,
                                                      kind: key.kind, providerID: key.providerID,
                                                      offsetMs: offset.offsetMs, updatedAt: offset.updatedAt))
    }

    /// Tar bort en profil som raderats på en annan enhet. Ingen gravsten skapas här (den kom från synken).
    private func removeProfileLocally(_ id: UUID) {
        persisted.pinMissing.removeAll { $0 == id }
        if let remove = hooks.removeProfile {
            remove(id)
            return
        }
        profiles.delete(id: id)
        for key in [ProfileKeys.progress(id), ProfileKeys.settings(id), ProfileKeys.personal(id)] {
            defaults.removeObject(forKey: key)
        }
        try? pins.removePin(profileID: id)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(persisted) { defaults.set(data, forKey: Self.stateKey) }
    }
}
