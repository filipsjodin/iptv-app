import Foundation
import PlaybackCore

public enum ProfileKeys {
    public static func progress(_ id: UUID) -> String { "userstate.progress.v1.\(id)" }
    public static func settings(_ id: UUID) -> String { "settings.playback.v1.\(id)" }
    public static func personal(_ id: UUID) -> String { "personal.v1.\(id)" }
}

public enum ProfileMigration {
    static let legacyProgressKey = "userstate.progress.v1"

    /// Skapar "Profil 1" för varje spellista utan profiler och flyttar den globala progressen/inställningarna dit.
    /// De globala nycklarna tas bort först när alla givna spellistor har profiler. Idempotent.
    /// Returnerar de profiler som skapades i detta anrop.
    @discardableResult
    public static func migrateLegacy(defaults: UserDefaults, playlists: [UUID], profiles: ProfileStore) -> [UUID: Profile] {
        let legacy = UserDefaultsUserStateStore(defaults: defaults, key: legacyProgressKey)
        let entries = legacy.allEntries()
        let hasSettings = defaults.data(forKey: PlaybackSettings.defaultsKey) != nil
        let settings = PlaybackSettings.load(from: defaults)
        var created: [UUID: Profile] = [:]
        for playlist in playlists where profiles.profiles(playlistID: playlist).isEmpty {
            let p = Profile(playlistID: playlist, name: "Profil 1", avatar: "person.crop.circle")
            let target = UserDefaultsUserStateStore(defaults: defaults, key: ProfileKeys.progress(p.id))
            for e in entries where e.key.playlistID == playlist { target.save(e) }
            if hasSettings { settings.save(to: defaults, key: ProfileKeys.settings(p.id)) }
            profiles.save(p)
            created[playlist] = p
        }
        // Alla givna spellistor har nu profiler: ta bort de globala nycklarna.
        defaults.removeObject(forKey: legacyProgressKey)
        defaults.removeObject(forKey: PlaybackSettings.defaultsKey)
        return created
    }
}
