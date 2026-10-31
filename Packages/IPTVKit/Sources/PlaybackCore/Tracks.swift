import Foundation

public enum TrackKind: String, Codable, Sendable {
    case audio, subtitle
}

public struct MediaTrack: Hashable, Codable, Sendable {
    public var id: String
    public var kind: TrackKind
    public var languageCode: String?
    public var title: String
    public var codec: String?
    public var channelCount: Int?
    public var isAtmos: Bool
    public var isDefault: Bool
    public var isForced: Bool

    public init(id: String, kind: TrackKind, languageCode: String?, title: String, codec: String?,
                channelCount: Int?, isAtmos: Bool, isDefault: Bool, isForced: Bool) {
        self.id = id
        self.kind = kind
        self.languageCode = languageCode
        self.title = title
        self.codec = codec
        self.channelCount = channelCount
        self.isAtmos = isAtmos
        self.isDefault = isDefault
        self.isForced = isForced
    }
}

public extension MediaTrack {
    /// Prefix för externa undertextspår (hämtade utanför strömmen, t.ex. från OpenSubtitles).
    static let externalIDPrefix = "ext:"

    /// Spår-id för en extern undertext: `ext:<fileID>`.
    static func externalID(fileID: Int) -> String { "\(externalIDPrefix)\(fileID)" }

    /// Sant för spår vars id är `ext:<fileID>`.
    var isExternal: Bool {
        id.hasPrefix(Self.externalIDPrefix) && Int(id.dropFirst(Self.externalIDPrefix.count)) != nil
    }

    /// `fileID` för ett externt spår, annars nil.
    var externalFileID: Int? {
        isExternal ? Int(id.dropFirst(Self.externalIDPrefix.count)) : nil
    }
}

public enum SubtitleMode: String, Codable, CaseIterable, Sendable {
    case off, always, foreignAudioOnly
}

public struct TrackPreferences: Codable, Equatable, Sendable {
    public var audioLanguages: [String]
    public var subtitleMode: SubtitleMode
    public var subtitleLanguages: [String]
    public var preferSurround: Bool

    private enum CodingKeys: String, CodingKey { case audioLanguages, subtitleMode, subtitleLanguages, preferSurround }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioLanguages = try c.decodeIfPresent([String].self, forKey: .audioLanguages) ?? ["sv", "en"]
        subtitleMode = try c.decodeIfPresent(SubtitleMode.self, forKey: .subtitleMode) ?? .foreignAudioOnly
        subtitleLanguages = try c.decodeIfPresent([String].self, forKey: .subtitleLanguages) ?? ["sv", "en"]
        preferSurround = try c.decodeIfPresent(Bool.self, forKey: .preferSurround) ?? true
    }

    public init(audioLanguages: [String] = ["sv", "en"], subtitleMode: SubtitleMode = .foreignAudioOnly,
                subtitleLanguages: [String] = ["sv", "en"], preferSurround: Bool = true) {
        self.audioLanguages = audioLanguages
        self.subtitleMode = subtitleMode
        self.subtitleLanguages = subtitleLanguages
        self.preferSurround = preferSurround
    }
}

public struct TrackChoice: Equatable, Sendable {
    public var audioID: String?
    public var subtitleID: String?

    public init(audioID: String?, subtitleID: String?) {
        self.audioID = audioID
        self.subtitleID = subtitleID
    }
}

public enum TrackSelector {
    public static func choose(audio: [MediaTrack], subtitles: [MediaTrack], prefs: TrackPreferences) -> TrackChoice {
        let chosenAudio = chooseAudio(audio, prefs: prefs)
        let subtitle = chooseSubtitle(subtitles, audioLanguage: LanguageCode.normalize(chosenAudio?.languageCode), prefs: prefs)
        return TrackChoice(audioID: chosenAudio?.id, subtitleID: subtitle?.id)
    }

    private static func chooseAudio(_ audio: [MediaTrack], prefs: TrackPreferences) -> MediaTrack? {
        for lang in prefs.audioLanguages.compactMap({ LanguageCode.normalize($0) }) {
            let inLang = audio.filter { LanguageCode.normalize($0.languageCode) == lang }
            if inLang.isEmpty { continue }
            if prefs.preferSurround {
                // Atmos före flest kanaler före övriga; första spåret vinner vid lika.
                var best = inLang[0]
                for c in inLang.dropFirst() where surroundRank(c) > surroundRank(best) { best = c }
                return best
            }
            return inLang.first(where: { $0.isDefault }) ?? inLang[0]
        }
        return audio.first(where: { $0.isDefault }) ?? audio.first
    }

    private static func surroundRank(_ t: MediaTrack) -> Int {
        (t.isAtmos ? 1_000 : 0) + (t.channelCount ?? 0)
    }

    private static func chooseSubtitle(_ subs: [MediaTrack], audioLanguage: String?, prefs: TrackPreferences) -> MediaTrack? {
        // Forced-text i det valda ljudspråket visas alltid.
        let forced = audioLanguage.flatMap { lang in
            subs.first { $0.isForced && LanguageCode.normalize($0.languageCode) == lang }
        }
        func regular() -> MediaTrack? {
            for lang in prefs.subtitleLanguages.compactMap({ LanguageCode.normalize($0) }) {
                if let hit = subs.first(where: { !$0.isForced && LanguageCode.normalize($0.languageCode) == lang }) { return hit }
            }
            return nil
        }
        switch prefs.subtitleMode {
        case .off:
            return forced
        case .always:
            return regular() ?? forced
        case .foreignAudioOnly:
            let preferred = prefs.audioLanguages.first.flatMap { LanguageCode.normalize($0) }
            if let audioLanguage, audioLanguage == preferred { return forced }
            return regular() ?? forced
        }
    }

    /// Hittar motsvarande spår i en annan motors spårlista (språk, sedan Atmos/kanalprofil).
    public static func matching(_ track: MediaTrack?, in candidates: [MediaTrack]) -> MediaTrack? {
        guard let track, let lang = LanguageCode.normalize(track.languageCode) else { return nil }
        let sameLang = candidates.filter { $0.kind == track.kind && LanguageCode.normalize($0.languageCode) == lang }
        guard var best = sameLang.first else { return nil }
        func score(_ c: MediaTrack) -> Int {
            (c.isAtmos == track.isAtmos ? 4 : 0) + (c.channelCount == track.channelCount ? 2 : 0) + (c.isForced == track.isForced ? 1 : 0)
        }
        for c in sameLang.dropFirst() where score(c) > score(best) { best = c }
        return best
    }
}
