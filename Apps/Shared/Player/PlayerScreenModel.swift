import Foundation
import Observation
import os
import Playback
import PlaybackCore
import Providers
import SwiftUI

/// En variant av live-kanalen i kvalitetsmenyn och förslaget (bäst först i listan).
struct LiveVariantOption: Identifiable, Equatable, Sendable {
    /// Variantens `providerID`.
    let id: String
    let name: String
    let quality: VariantQuality
    let isCurrent: Bool
}

/// Vad spelarvyn gör när appens scenfas ändras.
enum ScenePolicy: Equatable, Sendable {
    case none, save, pauseAndSave
}

/// Spelarvyns tillstånd utöver sessionen: nedräkning till nästa avsnitt, info-text och menyval.
@MainActor @Observable
final class PlayerScreenModel {
    static let countdownSeconds = 10
    private static let signposter = OSSignposter(subsystem: "se.sjodin.iptv", category: "zap")

    private(set) var session: PlaybackSession
    /// Sekunder kvar till nästa avsnitt startar; nil när ingen nedräkning pågår.
    private(set) var countdown: Int?
    /// Ökas vid varje `tick()`. Motorns tid, spår och videoinfo observeras inte, så vyer som visar dem läser
    /// värdet för att ritas om varje sekund.
    private(set) var tickCount = 0
    /// Satt mellan AVKits callbacks för start och stopp av bild-i-bild (iOS).
    var pictureInPictureActive = false
    /// Satt medan AVKit visar sin egen helskärmspresentation (iOS); då kan värdvyn försvinna tillfälligt
    /// utan att uppspelningen ska stoppas.
    var systemFullScreenActive = false
    /// Nedräkningen är pausad (uppspelningen pausad eller misslyckad) och fortsätter när uppspelningen gör det.
    private(set) var countdownPaused = false
    /// Satt när anslutningsvakten återkallat uppspelningen till förmån för en annan; spelaren är då stoppad.
    private(set) var revokedMessage: String?
    /// Variantens `providerID` som spelas nu (live med kvalitetsmeny); nil utanför live.
    private(set) var currentVariantID: String?
    /// Lägre variant att föreslå efter upprepad buffring; nil när inget förslag visas.
    private(set) var suggestLower: LiveVariantOption?

    @ObservationIgnored private let nextEpisodeProvider: (@MainActor () async -> PlaybackRequest?)?
    @ObservationIgnored private let makeSession: @MainActor (PlaybackRequest) -> PlaybackSession
    @ObservationIgnored private let stepper: @MainActor () async -> Void
    @ObservationIgnored private let setIdleTimerDisabled: @MainActor (Bool) -> Void
    /// Senast satta värde för skärmsläckarspärren; nil innan något satts.
    @ObservationIgnored private(set) var idleTimerDisabled: Bool?
    @ObservationIgnored private(set) var countdownTask: Task<Void, Never>?
    /// Byte till nästa avsnitt som startats av att avsnittet tog slut.
    @ObservationIgnored private(set) var advanceTask: Task<Void, Never>?
    /// Nedräkningen erbjuds en gång per avsnitt, även om användaren avbryter den.
    @ObservationIgnored private var countdownOffered = false
    @ObservationIgnored private var advancing = false
    @ObservationIgnored private var stopped = false
    /// Pågående `channelSwitch`-intervall (från tryck till första bildruta).
    @ObservationIgnored private var channelSwitchInterval: OSSignpostIntervalState?
    /// Live: kanalerna som varianterna slås upp i och hur en variants begäran byggs (nil i barnläge).
    @ObservationIgnored private var liveGroups: [ChannelGroup] = []
    @ObservationIgnored private var liveVariantRequest: (@MainActor (ChannelGroup, LiveStream) -> PlaybackRequest?)?
    @ObservationIgnored private var advisor = BufferingAdvisor()
    /// Motorns läge vid förra kontrollen, så att bara själva starten av buffringen räknas som ett stannande.
    @ObservationIgnored private var lastObservedState: PlaybackState?
    /// Motorn som observerades senast; ett motorbyte börjar om (uppstarten räknas inte).
    @ObservationIgnored private var observedEngine: ObjectIdentifier?
    /// Strömmen har spelat sedan start eller motorbyte; buffring före första uppspelningen är inget stannande.
    @ObservationIgnored private var hasPlayed = false
    /// Visar skärmen HDR? Utan HDR erbjuds inga HDR-varianter (spec 8.1).
    @ObservationIgnored private var displaySupportsHDR = true
    /// Pågående kvalitetsbyte; ett kanalbyte (zappning) ersätter det.
    @ObservationIgnored private var variantTask: Task<Bool, Never>?
    /// Kanaler (grupp-id) där användaren avvisat förslaget; gäller resten av uppspelningen.
    @ObservationIgnored private var dismissedSuggestions: Set<String> = []
    @ObservationIgnored private let now: @MainActor () -> Date
    /// Vet vilken motor som skapades senast, även om den redan stängts efter ett fel (för "Prova …" i felvyn).
    @ObservationIgnored let engineRecorder: EngineKindRecorder
    /// Anslutningsvakt och spellista; utan vakt (äldre tester) begärs ingen anslutningsplats.
    @ObservationIgnored private let broker: StreamConnectionBroker?
    @ObservationIgnored private let playlistID: UUID?
    /// Anslutningsplatsen för hela spelarvyn (behålls vid byte till nästa avsnitt).
    @ObservationIgnored private(set) var lease: StreamLease?
    /// Stängning med anslutningsplats: väntar tills motorn släppt strömmen och släpper sedan platsen. Hålls kvar
    /// så att en återkallning (och tester) kan vänta in den.
    @ObservationIgnored private(set) var closeTask: Task<Void, Never>?

    /// - Parameters:
    ///   - makeSession: skapar sessionen för nästa avsnitt.
    ///   - stepper: väntar ett steg (en sekund) i nedräkningen; injiceras i tester.
    ///   - engineRecorder: samma instans som sessionernas motorfabrik rapporterar till.
    ///   - setIdleTimerDisabled: sätter `UIApplication.isIdleTimerDisabled`; injiceras i tester.
    ///   - broker: anslutningsvakten; en uppspelningsplats för `playlistID` begärs innan sessionen startar.
    ///   - now: klockan för buffringsförslaget; injiceras i tester.
    init(session: PlaybackSession,
         nextEpisodeProvider: (@MainActor () async -> PlaybackRequest?)?,
         makeSession: @escaping @MainActor (PlaybackRequest) -> PlaybackSession,
         stepper: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(1)) },
         engineRecorder: EngineKindRecorder = EngineKindRecorder(),
         setIdleTimerDisabled: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 },
         broker: StreamConnectionBroker? = nil, playlistID: UUID? = nil,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
        self.broker = broker
        self.playlistID = playlistID
        self.session = session
        self.setIdleTimerDisabled = setIdleTimerDisabled
        self.engineRecorder = engineRecorder
        self.nextEpisodeProvider = nextEpisodeProvider
        self.makeSession = makeSession
        self.stepper = stepper
    }

    var hasNextEpisode: Bool { nextEpisodeProvider != nil }

    // MARK: - Livscykel

    /// Begär en uppspelningsplats (återkallar vid behov en annan uppspelning) och startar sedan sessionen.
    func start() async {
        if let broker, let playlistID, lease == nil {
            let granted = await broker.acquire(.playback, playlistID: playlistID) { [weak self] in
                await self?.revoked()
            }
            // Avbruten medan vi väntade: ingen plats, ingen start.
            guard let granted else { return }
            guard !stopped else {
                await broker.release(granted)
                return
            }
            lease = granted
        }
        guard !stopped else { return }
        await session.start()
    }

    /// Vakten återkallar platsen: stoppa och vänta tills strömmen släppts, och visa meddelandet.
    func revoked() async {
        guard !stopped else {
            // Redan stängd: vakten får platsen först när strömmen verkligen är släppt.
            await closeTask?.value
            return
        }
        stopped = true
        variantTask?.cancel()
        lease = nil   // vakten tar själv bort en återkallad plats
        cancelCountdown()
        revokedMessage = String(localized: "Playback was interrupted by another playback.")
        await session.stopAndWait()
        applyIdleTimer()
    }

    /// Anropas av värdvyn en gång i sekunden.
    func tick() {
        guard !stopped else { return }
        session.tick()
        tickCount &+= 1
        observeBuffering()
        syncCountdown()
        applyIdleTimer()
    }

    // MARK: - Skärmsläckare

    /// Apples spelare håller själv skärmsläckaren borta under uppspelning; VLC gör det inte. Spärren sätts
    /// därför bara när VLC spelar eller buffrar, och släpps i alla andra lägen.
    static func shouldDisableIdleTimer(engine: EngineKind?, state: PlaybackState?, hasError: Bool,
                                       stopped: Bool) -> Bool {
        guard !stopped, !hasError, engine == .vlc else { return false }
        return state == .playing || state == .buffering
    }

    /// Sätter skärmsläckarspärren efter aktuellt läge. Anropas vid varje tick, när sessionens state ändras
    /// och vid stopp.
    func applyIdleTimer() {
        let disable = Self.shouldDisableIdleTimer(engine: session.engine?.kind, state: session.engine?.state,
                                                  hasError: session.errorMessageKey != nil, stopped: stopped)
        guard disable != idleTimerDisabled else { return }
        idleTimerDisabled = disable
        setIdleTimerDisabled(disable)
    }

    func pauseAndSave() {
        session.pauseAndSave()
    }

    /// Stoppar nedräkning och uppspelning definitivt (Stäng). Kan anropas flera gånger.
    func stop() {
        guard closeTask == nil else { return }
        stopped = true
        variantTask?.cancel()
        cancelCountdown()
        endChannelSwitchSignpost()
        guard let broker, let lease else {
            session.stop()
            applyIdleTimer()
            return
        }
        // Med en anslutningsplats: platsen släpps först när motorn stängt strömmen, så att nästa uppspelning
        // på ett konto med en enda anslutning inte överlappar den här. Ljudet tystnar direkt.
        self.lease = nil
        session.engine?.pause()
        applyIdleTimer()
        let session = session
        closeTask = Task {
            await session.stopAndWait()
            session.stop()   // släpper ljudsessionen; motorn är redan stängd
            await broker.release(lease)
        }
    }

    /// Värdvyn försvann. Säkerhetsnät: stoppar bara om AVKit inte visar sin egen helskärm just nu.
    /// Returnerar om spelaren stoppades.
    @discardableResult
    func viewDisappeared() -> Bool {
        guard !systemFullScreenActive else { return false }
        stop()
        return true
    }

    // MARK: - Scenfas

    /// tvOS: inaktiv/bakgrund pausar och sparar. iOS: inaktiv sparar bara. I bakgrunden pausar Apples spelare
    /// bara om varken bild-i-bild eller AirPlay (extern uppspelning) är aktiv; VLC pausar alltid.
    static func scenePolicy(phase: ScenePhase, engine: EngineKind?, pipActive: Bool, externalActive: Bool,
                            isTV: Bool) -> ScenePolicy {
        switch phase {
        case .active:
            return .none
        case .inactive:
            return isTV ? .pauseAndSave : .save
        case .background:
            if isTV { return .pauseAndSave }
            if engine == .avPlayer, pipActive || externalActive { return .save }
            return .pauseAndSave
        @unknown default:
            return .none
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard !stopped else { return }
        #if os(tvOS)
        let isTV = true
        #else
        let isTV = false
        #endif
        let external = (session.engine as? AVPlayerEngine)?.player.isExternalPlaybackActive ?? false
        switch Self.scenePolicy(phase: phase, engine: session.engine?.kind, pipActive: pictureInPictureActive,
                                externalActive: external, isTV: isTV) {
        case .none: break
        case .save: session.saveNow()
        case .pauseAndSave: session.pauseAndSave()
        }
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
        countdownPaused = false
    }

    private var isPlaying: Bool {
        guard session.errorMessageKey == nil, let state = session.engine?.state else { return false }
        return state == .playing || state == .buffering
    }

    /// Startar, pausar eller återupptar nedräkningen efter uppspelningens läge. Anropas vid varje tick.
    private func syncCountdown() {
        // Avsnittet tog slut medan nedräkningen pågick (eller var frusen) eller innan den hann erbjudas:
        // gå direkt till nästa avsnitt. En nedräkning som användaren avbröt respekteras.
        if session.errorMessageKey == nil, session.engine?.state == .ended, nextEpisodeProvider != nil,
           countdown != nil || !countdownOffered, !advancing {
            cancelCountdown()
            countdownOffered = true
            // Egen task (inte countdownTask), så att nästa ticks pausregel inte avbryter laddningen.
            advanceTask = Task { [weak self] in await self?.advance() }
            return
        }
        let playing = isPlaying
        if countdownTask != nil {
            if !playing {
                // Pausad eller misslyckad uppspelning: frys nedräkningen.
                countdownTask?.cancel()
                countdownTask = nil
                countdownPaused = true
            } else if !session.nextEpisodeOffer {
                // Spolat tillbaka ur erbjudandefönstret: erbjud igen när slutet närmar sig.
                cancelCountdown()
                countdownOffered = false
            }
        } else if countdownPaused {
            guard playing else { return }
            if session.nextEpisodeOffer {
                countdownPaused = false
                countdownTask = Task { [weak self] in await self?.runCountdown() }
            } else {
                // Spolat tillbaka ur erbjudandefönstret: erbjud igen när slutet närmar sig.
                cancelCountdown()
                countdownOffered = false
            }
        } else if playing, session.nextEpisodeOffer {
            startNextEpisodeCountdown()
        }
    }

    /// "Nästa avsnitt" valt direkt.
    func playNextEpisodeNow() {
        cancelCountdown()
        Task { await advance() }
    }

    private func runCountdown() async {
        while true {
            // Kontrolleras även före första steget: en task som avbryts innan den hunnit starta får inte
            // tolka den nollställda nedräkningen som "klar" och byta avsnitt.
            guard !Task.isCancelled, let remaining = countdown else { return }
            if remaining <= 0 { break }
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
        // Vänta tills föregående ström släppts innan nästa öppnas (konton med en enda anslutning).
        await session.stopAndWait()
        guard !stopped else { return }
        let next = makeSession(request)
        session = next
        countdownOffered = false
        countdownPaused = false
        await next.start()
    }

    // MARK: - Kanalbyte (live)

    /// Byter live-kanal. Föregående session stängs med `stopAndWait` innan nästa öppnas; anslutningsplatsen
    /// (`lease`) behålls för hela spelarvyn, så ingen plats läcker och aldrig två strömmar är öppna. Avbryts
    /// tasken (ett nyare byte tar över) efter stängningen öppnas ingen ström. Returnerar om den nya sessionen
    /// startades.
    @discardableResult
    func switchChannel(to request: PlaybackRequest) async -> Bool {
        // En zappning ersätter ett pågående kvalitetsbyte, så att kanalvalet och strömmen aldrig skiljer sig åt.
        await supersedeVariantSwitch()
        return await performSwitch(to: request)
    }

    /// Avbryter ett pågående kvalitetsbyte och väntar tills det avslutats (det öppnar då ingen ström). Utan pågående
    /// byte återgår den direkt, utan att vänta.
    private func supersedeVariantSwitch() async {
        while let pending = variantTask {
            pending.cancel()
            _ = await pending.value
            if variantTask == pending { variantTask = nil }
        }
    }

    private func performSwitch(to request: PlaybackRequest) async -> Bool {
        guard !stopped else { return false }
        let previous = session
        await previous.stopAndWait()
        // Ett annat byte (zappning eller kvalitetsval) hann före under väntan: det äger redan den nya strömmen.
        guard !stopped, !Task.isCancelled, session === previous else { return false }
        let next = makeSession(request)
        session = next
        if liveVariantRequest != nil {
            currentVariantID = request.key.providerID
            resetBufferingAdvice()
        }
        await next.start()
        return !stopped && !Task.isCancelled
    }

    // MARK: - Kvalitet (live)

    /// Aktiverar kvalitetsmenyn och buffringsförslaget för live. `groups` är kanalerna varianterna slås upp i,
    /// `current` är `providerID` för strömmen som spelas, `displaySupportsHDR` styr om HDR-varianter erbjuds, och `request` bygger en variants begäran (nil i barnläge).
    func configureLive(groups: [ChannelGroup], current providerID: String, displaySupportsHDR: Bool,
                       request: @escaping @MainActor (ChannelGroup, LiveStream) -> PlaybackRequest?) {
        liveGroups = groups
        liveVariantRequest = request
        self.displaySupportsHDR = displaySupportsHDR
        currentVariantID = providerID
        resetBufferingAdvice()
    }

    private var currentLiveGroup: ChannelGroup? {
        guard let id = currentVariantID else { return nil }
        return liveGroups.first { $0.variants.contains { $0.providerID == id } }
    }

    private func option(_ group: ChannelGroup, at index: Int) -> LiveVariantOption {
        let stream = group.variants[index]
        let quality = group.quality(of: index)
        return LiveVariantOption(id: stream.providerID, name: quality.displayName(fallback: stream.name),
                                 quality: quality, isCurrent: stream.providerID == currentVariantID)
    }

    /// Varianterna skärmen får välja bland (index i `variants`, bäst först).
    private func allowedIndices(_ group: ChannelGroup) -> [Int] {
        group.variantIndices(displaySupportsHDR: displaySupportsHDR)
    }

    /// Kanalens varianter, bäst först (utan HDR-varianter på en SDR-skärm). Tom utanför live och när färre än två
    /// varianter återstår.
    var liveVariants: [LiveVariantOption] {
        guard liveVariantRequest != nil, let group = currentLiveGroup else { return [] }
        let indices = allowedIndices(group)
        guard indices.count >= 2 else { return [] }
        return indices.map { option(group, at: $0) }
    }

    /// Byter till en annan variant av kanalen (stängning före öppning, platsen behålls). Ett senare val eller en
    /// zappning ersätter ett pågående byte.
    func selectVariant(_ providerID: String) async {
        await supersedeVariantSwitch()
        guard !stopped, let makeRequest = liveVariantRequest, let group = currentLiveGroup,
              providerID != currentVariantID,
              let index = group.variants.firstIndex(where: { $0.providerID == providerID }),
              allowedIndices(group).contains(index),
              let request = makeRequest(group, group.variants[index]) else { return }
        let task = Task { await performSwitch(to: request) }
        variantTask = task
        _ = await task.value
        if variantTask == task { variantTask = nil }
    }

    /// Anropas vid varje tick och när sessionens state ändras. Varje start av buffring i en live-ström som redan
    /// spelat matas in i rådgivaren (inte uppstarten, motorbyten eller återupptagning efter paus); ger den ett
    /// förslag visas nästa lägre tillåtna variant (om den finns och förslaget inte redan avvisats för kanalen).
    func observeBuffering() {
        guard !stopped, liveVariantRequest != nil else { return }
        let engine = session.engine
        let engineID = engine.map { ObjectIdentifier($0) }
        if engineID != observedEngine {
            observedEngine = engineID
            hasPlayed = false
            lastObservedState = nil
        }
        let state = engine?.state
        let previous = lastObservedState
        lastObservedState = state
        if state == .playing { hasPlayed = true }
        guard state == .buffering, previous != .buffering, previous != .paused, hasPlayed,
              advisor.recordStall(at: now()) else { return }
        guard suggestLower == nil, let group = currentLiveGroup, !dismissedSuggestions.contains(group.id),
              let current = group.variants.firstIndex(where: { $0.providerID == currentVariantID }),
              let lower = allowedIndices(group).first(where: { $0 > current }) else { return }
        suggestLower = option(group, at: lower)
    }

    /// "Byt" i förslaget.
    func acceptSuggestion() async {
        guard let lower = suggestLower else { return }
        suggestLower = nil
        await selectVariant(lower.id)
    }

    /// "Inte nu": förslaget visas inte igen för kanalen under resten av uppspelningen.
    func dismissSuggestion() {
        if let group = currentLiveGroup { dismissedSuggestions.insert(group.id) }
        suggestLower = nil
    }

    /// Bannern tonade ut av sig själv: dölj utan att avvisa (ett nytt förslag kräver nya stannanden).
    func hideSuggestion() {
        suggestLower = nil
    }

    private func resetBufferingAdvice() {
        advisor.reset()
        lastObservedState = nil
        observedEngine = nil
        hasPlayed = false
        suggestLower = nil
    }

    /// Startar `channelSwitch`-intervallet vid tryck (bara ett åt gången; snabba tryck räknas från det första).
    func beginChannelSwitchSignpost() {
        guard channelSwitchInterval == nil else { return }
        channelSwitchInterval = Self.signposter.beginInterval("channelSwitch")
    }

    /// Avslutar intervallet när första bildrutan visas (sessionen spelar) eller bytet misslyckats.
    func endChannelSwitchSignpost() {
        guard let interval = channelSwitchInterval else { return }
        channelSwitchInterval = nil
        Self.signposter.endInterval("channelSwitch", interval)
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

    /// "Försök igen" i felvyn: samma motor igen.
    func retry() async {
        await session.retry()
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
