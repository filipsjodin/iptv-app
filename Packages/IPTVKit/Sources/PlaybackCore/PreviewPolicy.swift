import Foundation

/// Vilken sorts enhet förhandsvisningen visas på. Bara plattformen avgör autostart, aldrig enhetstypen.
public enum PreviewPlatform: Sendable {
    /// Apple TV: fokus startar förhandsvisningen av sig själv (§6.5).
    case tv
    /// iPhone och iPad: förhandsvisningen startar bara på uttryckligt tryck (§6.4).
    case handheld
}

/// Ren regel för när en förhandsvisning får starta. På iPhone/iPad får den aldrig starta av sig själv, så att den
/// aldrig tar en `max_connections`-plats utan att användaren bett om det.
public struct PreviewPolicy: Sendable {
    /// Startar förhandsvisningen när detaljsidan visas? Bara på tv.
    public static func autoStartsOnAppear(_ platform: PreviewPlatform) -> Bool {
        switch platform {
        case .tv: return true
        case .handheld: return false
        }
    }

    /// Får användaren starta en förhandsvisning (knappen visas)? Kräver att profilen har förhandsvisningar på och
    /// att profilen inte är en barnprofil.
    public static func allowsUserStartedPreview(_ platform: PreviewPlatform, previewsEnabled: Bool,
                                                kids: Bool) -> Bool {
        previewsEnabled && !kids
    }
}
