import Foundation
import Core

public struct PlaybackSettings: Codable, Equatable, Sendable {
    public static let defaultsKey = "settings.playback.v1"

    public var engine: EnginePreference
    public var tracks: TrackPreferences
    public var previewsEnabled: Bool
    public var previewSoundEnabled: Bool

    public init(engine: EnginePreference = .automatic, tracks: TrackPreferences = .init(),
                previewsEnabled: Bool = true, previewSoundEnabled: Bool = true) {
        self.engine = engine
        self.tracks = tracks
        self.previewsEnabled = previewsEnabled
        self.previewSoundEnabled = previewSoundEnabled
    }

    private enum CodingKeys: String, CodingKey { case engine, tracks, previewsEnabled, previewSoundEnabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(EnginePreference.self, forKey: .engine) ?? .automatic
        tracks = try c.decodeIfPresent(TrackPreferences.self, forKey: .tracks) ?? .init()
        previewsEnabled = try c.decodeIfPresent(Bool.self, forKey: .previewsEnabled) ?? true
        previewSoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .previewSoundEnabled) ?? true
    }

    public static func load(from defaults: UserDefaults, key: String = defaultsKey) -> PlaybackSettings {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(PlaybackSettings.self, from: data) else { return PlaybackSettings() }
        return value
    }

    public func save(to defaults: UserDefaults, key: String = defaultsKey) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

public enum NextEpisode {
    /// Nästa avsnitt i samma säsong, annars första avsnittet i nästa säsong som finns. Bara samma serie räknas.
    public static func after(_ current: Episode, in all: [Episode]) -> Episode? {
        all.filter { $0.seriesProviderID == current.seriesProviderID
                && ($0.season, $0.number) > (current.season, current.number) }
            .min { ($0.season, $0.number) < ($1.season, $1.number) }
    }
}
