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
    /// Globala inställningar tas bort när minst en spellista migrerats. Globala progressposter för spellistor som
    /// inte angavs bevaras under den globala nyckeln, som tas bort först när inget återstår. Idempotent.
    /// Anroparen måste ange alla kända spellist-ID:n, och migreringen måste köras innan någon store-instans på den
    /// globala nyckeln finns (en sådan instans skulle skriva över resultatet vid nästa save).
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
        if !playlists.isEmpty {
            // Behåll globala poster för spellistor som inte angavs; ta bort nyckeln först när inget återstår.
            for playlist in playlists { legacy.remove(playlistID: playlist) }
            if legacy.allEntries().isEmpty { defaults.removeObject(forKey: legacyProgressKey) }
            if !created.isEmpty { defaults.removeObject(forKey: PlaybackSettings.defaultsKey) }
        }
        return created
    }
}
