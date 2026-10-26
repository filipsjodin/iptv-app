import Foundation

public enum EngineKind: String, Codable, Sendable {
    case avPlayer, vlc
}

public enum EnginePreference: String, Codable, CaseIterable, Sendable {
    case automatic, avPlayer, vlc
}

public enum EngineSelector {
    /// Containers som AVPlayer spelar nativt. Progressiv TS ingår inte.
    private static let avPlayerContainers: Set<String> = ["mp4", "m4v", "mov", "m3u8"]
    private static let vlcContainers: Set<String> = ["mkv", "avi", "ts", "wmv", "flv", "webm", "mpg", "mpeg"]

    public static func initial(container: String?, isLive: Bool, preference: EnginePreference) -> EngineKind {
        switch preference {
        case .avPlayer: return .avPlayer
        case .vlc: return .vlc
        case .automatic:
            var c = (container ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            if c.hasPrefix(".") { c.removeFirst() }
            if avPlayerContainers.contains(c) { return .avPlayer }
            if vlcContainers.contains(c) { return .vlc }
            return .avPlayer
        }
    }

    /// Reservmotor efter ett fel. Bara i läget automatic och bara om den andra motorn inte redan provats.
    public static func fallback(after failed: EngineKind, preference: EnginePreference, alreadyTried: Set<EngineKind>) -> EngineKind? {
        guard preference == .automatic else { return nil }
        let other: EngineKind = failed == .avPlayer ? .vlc : .avPlayer
        return alreadyTried.contains(other) ? nil : other
    }
}
