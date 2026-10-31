import Foundation
import PlaybackCore
import Subtitles

/// En extern undertext som ska läggas till i en motor. Playback-sidans motsvarighet till appens lagrade
/// undertext (`StoredSubtitle` i `Library`): IPTVPlayback får inte bero på IPTVPlatform.
public struct ExternalSubtitle: Sendable, Hashable {
    /// `file_id` hos OpenSubtitles; ger spår-id `ext:<fileID>`.
    public var fileID: Int
    public var fileURL: URL
    public var language: String?
    /// Visningsnamn (releasenamnet).
    public var title: String

    public init(fileID: Int, fileURL: URL, language: String?, title: String) {
        self.fileID = fileID
        self.fileURL = fileURL
        self.language = language
        self.title = title
    }
}

public enum ExternalSubtitleError: Error, Equatable, Sendable {
    /// Motorn saknar stöd för externa undertexter (standardimplementationen).
    case unsupported
    /// Filen saknas, kan inte läsas eller innehåller inga cues.
    case unreadable
    /// Ingen uppspelning är laddad i motorn.
    case notLoaded
}

/// Läser och tolkar en undertextfil utanför huvudtråden.
public enum ExternalSubtitleLoader {
    public static func load(_ fileURL: URL) async throws -> SubtitleTrack {
        let result: SubtitleTrack? = await Task.detached(priority: .utility) { () -> SubtitleTrack? in
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            let cues = SubtitleParser.parse(SubtitleDecoder.decode(data))
            return cues.isEmpty ? nil : SubtitleTrack(cues: cues)
        }.value
        try Task.checkCancellation()
        guard let result else { throw ExternalSubtitleError.unreadable }
        return result
    }
}

/// Externa spår med tolkade cues och förskjutning; delas av AVPlayer-motorn och `FakeEngine`.
public struct ExternalSubtitleSet: Sendable {
    private struct Entry: Sendable {
        var track: MediaTrack
        var cues: SubtitleTrack
    }

    private var entries: [Entry] = []

    public init() {}

    public var tracks: [MediaTrack] { entries.map(\.track) }
    public var isEmpty: Bool { entries.isEmpty }

    public static func mediaTrack(fileID: Int, language: String?, title: String) -> MediaTrack {
        MediaTrack(id: MediaTrack.externalID(fileID: fileID), kind: .subtitle,
                   languageCode: LanguageCode.normalize(language), title: title, codec: nil, channelCount: nil,
                   isAtmos: false, isDefault: false, isForced: false)
    }

    /// Lägger till (eller ersätter) ett spår och returnerar dess `MediaTrack`.
    @discardableResult
    public mutating func add(fileID: Int, language: String?, title: String, cues: SubtitleTrack) -> MediaTrack {
        let track = Self.mediaTrack(fileID: fileID, language: language, title: title)
        if let i = entries.firstIndex(where: { $0.track.id == track.id }) {
            entries[i] = Entry(track: track, cues: cues)
        } else {
            entries.append(Entry(track: track, cues: cues))
        }
        return track
    }

    public func contains(id: String) -> Bool { entries.contains { $0.track.id == id } }

    public mutating func removeAll() { entries = [] }

    /// Uppslag för det valda externa spåret; nil om inget externt spår är valt. Värdena (spår och förskjutning)
    /// fångas vid anropet, så värden ska läsa `externalCueProvider` på nytt vid varje uppslag.
    public func cueProvider(selectedID: String?, offset: Double) -> ((Double) -> SubtitleCue?)? {
        guard let selectedID, let entry = entries.first(where: { $0.track.id == selectedID }) else { return nil }
        let cues = entry.cues
        return { time in cues.cue(at: time, offset: offset) }
    }
}
