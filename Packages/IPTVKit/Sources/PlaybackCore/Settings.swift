import Foundation
import Core

/// Uppspelningsinställningar för en profil. `updatedAt` är en enda tidsstämpel för hela blobben (record-LWW vid
/// synkronisering; avviker från "per fält" i specen). Saknad tidsstämpel = `Date.distantPast`, så att orörda
/// standardinställningar och gamla blobbar aldrig skriver över nyare fjärrdata.
public struct PlaybackSettings: Codable, Equatable, Sendable {
    public static let defaultsKey = "settings.playback.v1"

    public var engine: EnginePreference
    public var tracks: TrackPreferences
    public var previewsEnabled: Bool
    public var previewSoundEnabled: Bool
    /// Utseende för externa (nedladdade) undertexter.
    public var subtitleAppearance: SubtitleAppearance
    /// Inställningar för nedladdningar (iPhone/iPad).
    public var downloads: DownloadSettings
    /// Senaste ändring; sätts med `touch(now:)` där inställningarna sparas (se `ProfileSession`).
    public var updatedAt: Date

    /// Markerar inställningarna som ändrade nu.
    public mutating func touch(now: Date) { updatedAt = now }

    public init(engine: EnginePreference = .automatic, tracks: TrackPreferences = .init(),
                previewsEnabled: Bool = true, previewSoundEnabled: Bool = true,
                subtitleAppearance: SubtitleAppearance = .init(), downloads: DownloadSettings = .init(),
                updatedAt: Date = .distantPast) {
        self.engine = engine
        self.tracks = tracks
        self.previewsEnabled = previewsEnabled
        self.previewSoundEnabled = previewSoundEnabled
        self.subtitleAppearance = subtitleAppearance
        self.downloads = downloads
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case engine, tracks, previewsEnabled, previewSoundEnabled, subtitleAppearance, downloads, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(EnginePreference.self, forKey: .engine) ?? .automatic
        tracks = try c.decodeIfPresent(TrackPreferences.self, forKey: .tracks) ?? .init()
        previewsEnabled = try c.decodeIfPresent(Bool.self, forKey: .previewsEnabled) ?? true
        previewSoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .previewSoundEnabled) ?? true
        subtitleAppearance = try c.decodeIfPresent(SubtitleAppearance.self, forKey: .subtitleAppearance) ?? .init()
        downloads = (try? c.decodeIfPresent(DownloadSettings.self, forKey: .downloads)) ?? .init()
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? .distantPast
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

/// Inställningar för nedladdningar. Varje fält avkodas för sig så att äldre blobbar får standardvärden.
public struct DownloadSettings: Codable, Equatable, Sendable {
    /// Hämta bara via wifi.
    public var wifiOnly: Bool
    /// Radera en nedladdning automatiskt när titeln är sedd.
    public var autoDeleteWatched: Bool
    /// Hämta nästa avsnitt automatiskt (via wifi).
    public var autoNextEpisode: Bool

    public init(wifiOnly: Bool = true, autoDeleteWatched: Bool = false, autoNextEpisode: Bool = false) {
        self.wifiOnly = wifiOnly
        self.autoDeleteWatched = autoDeleteWatched
        self.autoNextEpisode = autoNextEpisode
    }

    private enum CodingKeys: String, CodingKey { case wifiOnly, autoDeleteWatched, autoNextEpisode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wifiOnly = (try? c.decodeIfPresent(Bool.self, forKey: .wifiOnly)) ?? true
        autoDeleteWatched = (try? c.decodeIfPresent(Bool.self, forKey: .autoDeleteWatched)) ?? false
        autoNextEpisode = (try? c.decodeIfPresent(Bool.self, forKey: .autoNextEpisode)) ?? false
    }
}
