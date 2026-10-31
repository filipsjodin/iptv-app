import Foundation
import Core

public struct PlaybackSettings: Codable, Equatable, Sendable {
    public static let defaultsKey = "settings.playback.v1"

    public var engine: EnginePreference
    public var tracks: TrackPreferences
    public var previewsEnabled: Bool
    public var previewSoundEnabled: Bool
    /// Utseende för externa (nedladdade) undertexter.
    public var subtitleAppearance: SubtitleAppearance

    public init(engine: EnginePreference = .automatic, tracks: TrackPreferences = .init(),
                previewsEnabled: Bool = true, previewSoundEnabled: Bool = true,
                subtitleAppearance: SubtitleAppearance = .init()) {
        self.engine = engine
        self.tracks = tracks
        self.previewsEnabled = previewsEnabled
        self.previewSoundEnabled = previewSoundEnabled
        self.subtitleAppearance = subtitleAppearance
    }

    private enum CodingKeys: String, CodingKey { case engine, tracks, previewsEnabled, previewSoundEnabled, subtitleAppearance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(EnginePreference.self, forKey: .engine) ?? .automatic
        tracks = try c.decodeIfPresent(TrackPreferences.self, forKey: .tracks) ?? .init()
        previewsEnabled = try c.decodeIfPresent(Bool.self, forKey: .previewsEnabled) ?? true
        previewSoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .previewSoundEnabled) ?? true
        subtitleAppearance = try c.decodeIfPresent(SubtitleAppearance.self, forKey: .subtitleAppearance) ?? .init()
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

/// Hur externa undertexter ritas: storlek, färg och bakgrund. Varje fält avkodas för sig och faller tillbaka på
/// standardvärdet om det saknas eller har ett okänt värde, så att äldre och nyare blobbar går att läsa.
public struct SubtitleAppearance: Codable, Equatable, Sendable {
    public enum Size: String, Codable, CaseIterable, Sendable { case small, medium, large, extraLarge }
    public enum Palette: String, Codable, CaseIterable, Sendable { case white, yellow, cyan }
    public enum Background: String, Codable, CaseIterable, Sendable { case none, shadow, box }

    public var size: Size
    public var palette: Palette
    public var background: Background

    public init(size: Size = .medium, palette: Palette = .white, background: Background = .shadow) {
        self.size = size
        self.palette = palette
        self.background = background
    }

    private enum CodingKeys: String, CodingKey { case size, palette, background }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = (try? c.decodeIfPresent(Size.self, forKey: .size)) ?? .medium
        palette = (try? c.decodeIfPresent(Palette.self, forKey: .palette)) ?? .white
        background = (try? c.decodeIfPresent(Background.self, forKey: .background)) ?? .shadow
    }
}
