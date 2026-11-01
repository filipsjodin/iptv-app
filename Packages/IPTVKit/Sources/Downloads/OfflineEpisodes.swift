import Foundation

/// Ett nedladdat och färdigt avsnitt, så som offlinevalet av "nästa avsnitt" ser det.
public struct OfflineEpisode: Sendable, Equatable {
    public var providerID: String
    public var season: Int
    public var number: Int

    public init(providerID: String, season: Int, number: Int) {
        self.providerID = providerID
        self.season = season
        self.number = number
    }
}

/// Ren logik för offlineuppspelning.
public enum OfflinePlayback {
    /// Alla senare avsnitt än `currentProviderID`, i ordning (säsong, avsnitt), bland de avsnitt som anroparen
    /// redan filtrerat till nedladdade och färdiga. Tomt när nuvarande avsnitt inte finns i listan.
    public static func following(_ currentProviderID: String, in available: [OfflineEpisode]) -> [OfflineEpisode] {
        guard let current = available.first(where: { $0.providerID == currentProviderID }) else { return [] }
        return available
            .filter { ($0.season, $0.number) > (current.season, current.number) }
            .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }

    /// Nästa avsnitt efter `currentProviderID`. Avsnitt som inte är nedladdade hoppas över (de ingår inte i
    /// `available`); `nil` när det inte finns något senare avsnitt eller nuvarande saknas i listan.
    public static func nextEpisode(after currentProviderID: String, in available: [OfflineEpisode]) -> OfflineEpisode? {
        following(currentProviderID, in: available).first
    }

    /// Containern för motorvalet ur den lagrade filens ändelse (gemener); `nil` utan ändelse.
    public static func container(forFileExtension ext: String) -> String? {
        let e = ext.lowercased()
        return e.isEmpty ? nil : e
    }
}
