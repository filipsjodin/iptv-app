import Foundation

/// Var i titeln förhandsvisningen startar (§6.5): cirka 10 % in, så att förtexter undviks
/// och slutet inte avslöjas.
public struct PreviewPlan: Equatable, Sendable {
    /// Startposition i sekunder; `nil` = från början eller live-kanten (ingen sökning).
    public let startAt: Double?
    /// Längdgräns i sekunder; `nil` = ingen gräns.
    public let maxDuration: Double?

    /// Live (§6.5/§8): ingen startposition, alltid live-kanten, och ingen längdgräns.
    public static func live() -> PreviewPlan {
        PreviewPlan(startAt: nil, maxDuration: nil)
    }

    /// Reservvärde när speltiden är okänd eller oanvändbar.
    public static let unknownDurationStart: Double = 120

    /// `min(max(duration * 0.10, 60), duration * 0.30)` avrundat till hela sekunder
    /// (till närmaste, hälften bort från noll). Okänd, icke-ändlig eller icke-positiv speltid ger 120.
    public static func startSeconds(duration: Double?) -> Double {
        guard let duration, duration.isFinite, duration > 0 else { return unknownDurationStart }
        return min(max(duration * 0.10, 60), duration * 0.30).rounded(.toNearestOrAwayFromZero)
    }
}

public enum PreviewFallback: Equatable, Sendable {
    case disabled, kidsDenied, unsupportedContainer, connectionBusy
}

public enum PreviewDecision: Equatable, Sendable {
    case play
    case artwork(reason: PreviewFallback)
}

public enum PreviewEligibility {
    /// Containrar som AVPlayer kan spela. Rå .ts räknas inte hit (motorvalet skickar den till VLC). MKV, AVI, WebM, .ts och okänt går till artwork (VLC används inte för förhandsvisningar).
    public static let avPlayableContainers: Set<String> = ["mp4", "m4v", "mov", "m3u8"]

    /// Orsakernas ordning: `disabled`, `kidsDenied`, `unsupportedContainer`, `connectionBusy`.
    /// `container` jämförs skiftlägesokänsligt och utan inledande punkt; nil eller tom är `unsupportedContainer`.
    public static func decide(settingsEnabled: Bool, kidsAllowed: Bool, container: String?,
                              playbackActive: Bool, leaseGranted: Bool) -> PreviewDecision {
        guard settingsEnabled else { return .artwork(reason: .disabled) }
        guard kidsAllowed else { return .artwork(reason: .kidsDenied) }
        guard isAVPlayable(container) else { return .artwork(reason: .unsupportedContainer) }
        guard !playbackActive, leaseGranted else { return .artwork(reason: .connectionBusy) }
        return .play
    }

    static func isAVPlayable(_ container: String?) -> Bool {
        guard var c = container?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        if c.hasPrefix(".") { c.removeFirst() }
        return avPlayableContainers.contains(c)
    }
}

/// Ger ett id först när samma id haft fokus i minst `settle` (standard 1,5 s). Ren värdetyp utan timer:
/// anroparen matar in tiden.
public struct FocusSettleGate: Sendable {
    public let settle: Duration
    private var current: (id: String, since: ContinuousClock.Instant)?

    public init(settle: Duration = .milliseconds(1500)) {
        self.settle = settle
    }

    /// Fokus på `id` vid `at`. Samma id igen nollställer inte klockan; ett annat id startar om från `at`.
    public mutating func focus(_ id: String, at: ContinuousClock.Instant) {
        if current?.id == id { return }
        current = (id, at)
    }

    /// Inget fokus (fokus lämnade raden eller vyn). Nollställer klockan.
    public mutating func clear() {
        current = nil
    }

    /// Id:t om det haft fokus i minst `settle` vid `at`, annars nil.
    public func settledID(at: ContinuousClock.Instant) -> String? {
        guard let current, at - current.since >= settle else { return nil }
        return current.id
    }
}
