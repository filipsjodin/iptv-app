import Foundation
import Observation
import Playback
import PlaybackCore

/// Spelarvyns tillstånd utöver sessionen: nedräkning till nästa avsnitt, info-text och menyval.
@MainActor @Observable
final class PlayerScreenModel {
    static let countdownSeconds = 10

    private(set) var session: PlaybackSession
    /// Sekunder kvar till nästa avsnitt startar; nil när ingen nedräkning pågår.
    private(set) var countdown: Int?
    /// Ökas vid varje `tick()`. Motorns tid, spår och videoinfo observeras inte, så vyer som visar dem läser
    /// värdet för att ritas om varje sekund.
    private(set) var tickCount = 0

    @ObservationIgnored private let nextEpisodeProvider: (@MainActor () async -> PlaybackRequest?)?
    @ObservationIgnored private let makeSession: @MainActor (PlaybackRequest) -> PlaybackSession
    @ObservationIgnored private let stepper: @MainActor () async -> Void
    @ObservationIgnored private(set) var countdownTask: Task<Void, Never>?
    /// Nedräkningen erbjuds en gång per avsnitt, även om användaren avbryter den.
    @ObservationIgnored private var countdownOffered = false
    @ObservationIgnored private var advancing = false
    @ObservationIgnored private var stopped = false
    /// Vet vilken motor som skapades senast, även om den redan stängts efter ett fel (för "Prova …" i felvyn).
    @ObservationIgnored let engineRecorder: EngineKindRecorder

    /// - Parameters:
    ///   - makeSession: skapar sessionen för nästa avsnitt.
    ///   - stepper: väntar ett steg (en sekund) i nedräkningen; injiceras i tester.
    ///   - engineRecorder: samma instans som sessionernas motorfabrik rapporterar till.
    init(session: PlaybackSession,
         nextEpisodeProvider: (@MainActor () async -> PlaybackRequest?)?,
         makeSession: @escaping @MainActor (PlaybackRequest) -> PlaybackSession,
         stepper: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(1)) },
         engineRecorder: EngineKindRecorder = EngineKindRecorder()) {
        self.session = session
        self.engineRecorder = engineRecorder
        self.nextEpisodeProvider = nextEpisodeProvider
        self.makeSession = makeSession
        self.stepper = stepper
    }

    var hasNextEpisode: Bool { nextEpisodeProvider != nil }

    // MARK: - Livscykel

    func start() async {
        await session.start()
    }

    /// Anropas av värdvyn en gång i sekunden.
    func tick() {
        guard !stopped else { return }
        session.tick()
        tickCount &+= 1
        if session.nextEpisodeOffer { startNextEpisodeCountdown() }
    }

    func pauseAndSave() {
        session.pauseAndSave()
    }

    /// Stoppar nedräkning och uppspelning; vyn har försvunnit.
    func stop() {
        stopped = true
        cancelCountdown()
        session.stop()
    }

    // MARK: - Nästa avsnitt

    func startNextEpisodeCountdown() {
        guard nextEpisodeProvider != nil, !countdownOffered, countdownTask == nil, !advancing, !stopped else { return }
        countdownOffered = true
        countdown = Self.countdownSeconds
        countdownTask = Task { [weak self] in await self?.runCountdown() }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    /// "Nästa avsnitt" valt direkt.
    func playNextEpisodeNow() {
        cancelCountdown()
        Task { await advance() }
    }

    private func runCountdown() async {
        while let remaining = countdown, remaining > 0 {
            await stepper()
            guard !Task.isCancelled, countdown != nil else { return }
            countdown = remaining - 1
        }
        countdownTask = nil
        countdown = nil
        await advance()
    }

    private func advance() async {
        guard !advancing, !stopped, let provider = nextEpisodeProvider else { return }
        advancing = true
        defer { advancing = false }
        guard let request = await provider(), !stopped else { return }
        session.stop()
        let next = makeSession(request)
        session = next
        countdownOffered = false
        await next.start()
    }

    // MARK: - Uppspelning

    func togglePlayPause() {
        guard let engine = session.engine else { return }
        if engine.state == .playing || engine.state == .buffering { engine.pause() } else { engine.play() }
    }

    func seek(to seconds: Double) async {
        await session.engine?.seek(to: seconds)
    }

    func switchEngine(to kind: EngineKind) async {
        await session.switchEngine(to: kind)
    }

    /// Motorn att erbjuda i felvyn: den andra än den som senast användes.
    var alternativeEngine: EngineKind {
        (session.engine?.kind ?? engineRecorder.last) == .vlc ? .avPlayer : .vlc
    }

    // MARK: - Info

    /// T.ex. "2160p · Dolby Vision · Atmos · Apple". Tom när ingen motor finns.
    var infoSummary: String {
        _ = tickCount
        guard let engine = session.engine else { return "" }
        let summary = engine.videoInfo.summary
        let name = engine.kind.displayName
        return summary.isEmpty ? name : "\(summary) · \(name)"
    }

    /// Rader i info-menyn: sammanfattningen plus upplösning och bithastighet när de är kända.
    var infoLines: [String] {
        let summary = infoSummary
        guard !summary.isEmpty, let info = session.engine?.videoInfo else { return [] }
        var lines = [summary]
        if let w = info.width, let h = info.height {
            lines.append(String(localized: "Resolution: \("\(w)×\(h)")"))
        }
        if let bitrate = info.bitrate, bitrate.isFinite, bitrate > 0 {
            let mbit = (bitrate / 1_000_000).formatted(.number.precision(.fractionLength(1)))
            lines.append(String(localized: "Bitrate: \("\(mbit) Mbit/s")"))
        }
        return lines
    }
}

/// Fylls i av motorfabriken när en motor skapas.
@MainActor
final class EngineKindRecorder {
    var last: EngineKind?
    init() {}
}

extension EngineKind {
    /// Namnet i gränssnittet.
    var displayName: String {
        switch self {
        case .avPlayer: "Apple"
        case .vlc: "VLC"
        }
    }
}
