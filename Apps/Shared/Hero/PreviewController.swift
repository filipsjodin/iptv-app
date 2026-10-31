import AVFoundation
import Foundation
import Library
import Observation
import os
import Playback
import PlaybackCore

/// Strömmen en förhandsvisning spelar (§6.5): filmen, eller S1E1 för en serie. `durationHint` (sekunder, t.ex. ur
/// TMDB:s speltid) avgör startpunkten via `PreviewPlan.startSeconds`; okänd ger reservvärdet.
struct PreviewSource: Sendable, Equatable {
    let url: URL
    let containerExtension: String?
    let durationHint: Double?
}

/// Förhandsvisningens läge för den fokuserade titeln.
enum PreviewState {
    /// Ingen förhandsvisning (inget fokus, eller fokus har nyss flyttats och väntar på att bli stillastående).
    case idle
    /// Fokus är stillastående och titeln klarar filtren; strömmen förbereds eller laddas.
    case starting
    /// Motorn spelar. Bara i det här läget visas videon (`PreviewSurface`).
    case playing(any PlayerEngine)
    /// Bara artwork. Skälet när det är känt; `nil` när strömmen inte startade i tid, inte kunde spelas eller saknas.
    case artwork(PreviewFallback?)
}

extension PreviewState: Equatable {
    static func == (lhs: PreviewState, rhs: PreviewState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.starting, .starting):
            return true
        case let (.playing(a), .playing(b)):
            return ObjectIdentifier(a) == ObjectIdentifier(b)
        case let (.artwork(a), .artwork(b)):
            return a == b
        default:
            return false
        }
    }
}

/// Anslutningsplatser för förhandsvisningar. Produktion: `StreamConnectionBroker` (syftet `.preview`); tester kan
/// lägga en räknande omslutning runt vakten.
protocol PreviewConnections: Sendable {
    func acquirePreview(playlistID: UUID, onRevoke: @escaping @Sendable () async -> Void) async -> StreamLease?
    func release(_ lease: StreamLease) async
}

extension StreamConnectionBroker: PreviewConnections {
    func acquirePreview(playlistID: UUID, onRevoke: @escaping @Sendable () async -> Void) async -> StreamLease? {
        await acquire(.preview, playlistID: playlistID, onRevoke: onRevoke)
    }
}

/// Ägarregel när flera vyer delar en kontroller (Hem och detaljsidorna ovanpå): den vy som senast visades äger
/// förhandsvisningen och byter titel med `focusChanged` (samma titel är en no-op, så ingen omstart). Ingen vy stoppar
/// en delad kontroller när den lämnas, eftersom ordningen mellan `onDisappear` och `onAppear` inte är given; bara
/// ägaren av kontrollern stoppar den (när den själv försvinner eller uppspelning startar).
///
/// Kontrollern äger förhandsvisningens livscykel: en tyst ström ur titelns egen spellista som startar när fokus stått still i
/// 1,5 s och stängs direkt när fokus flyttas (§6.5).
///
/// Anslutningen tas från `StreamConnectionBroker` med syftet `.preview`. Förhandsvisningar får bara en ledig plats
/// och tränger därför aldrig undan uppspelning; uppspelning kan däremot återkalla förhandsvisningen (`onRevoke`),
/// som då stängs direkt och faller tillbaka till artwork. Leasen släpps alltid först **efter** att motorn stängts
/// (`closeAndWait`), exakt en gång, oavsett om starten avbröts, tog för lång tid, misslyckades, återkallades eller
/// om ägaren släppte kontrollern utan `stop()` (då stänger `deinit` motorn och släpper leasen).
@MainActor @Observable
final class PreviewController {
    /// Allt kontrollern behöver utifrån; tester skickar testmotorer, en testklocka och en räknande vakt.
    struct Dependencies {
        var broker: any PreviewConnections
        var makeEngine: @MainActor () -> any PlayerEngine
        /// Ljud av/på för en motor (`PlayerEngine` har inget ljudreglage).
        var setMuted: @MainActor (any PlayerEngine, Bool) -> Void
        /// Strömmen för titeln i spellistan, eller `nil` om den inte finns.
        var resolve: @MainActor (LibraryItem, UUID) async -> PreviewSource?
        /// Den aktiva profilens inställningar (läses vid varje beslut).
        var settings: @MainActor () -> PlaybackSettings
        /// Klarar titeln profilens åldersfilter? Stängt som standard.
        var kidsAllowed: @MainActor (LibraryItem, UUID) async -> Bool
        var sleep: @Sendable (Duration) async throws -> Void
    }

    private static let signposter = OSSignposter(subsystem: "se.sjodin.iptv", category: "preview")

    /// Hur länge fokus ska stå still innan en förhandsvisning startar.
    static let settleDelay: Duration = FocusSettleGate().settle
    /// Har strömmen inte börjat spela inom den här tiden blir det artwork.
    static let startTimeout: Duration = .seconds(3)

    private(set) var state: PreviewState = .idle

    /// Sant när videon visas (för animationer i vyer).
    var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }

    @ObservationIgnored private let deps: Dependencies
    /// Svag referens till kontrollern för starter och `onRevoke`, så att inget asynkront arbete håller den vid liv.
    @ObservationIgnored private let handle = ControllerHandle()
    /// Försöket för den fokuserade titeln (nil när det avslutats).
    @ObservationIgnored private var current: Attempt?
    @ObservationIgnored private var focusedKey: FocusKey?
    /// Starter som inte kört klart än (även avbrutna), så att `stop()` kan vänta in dem.
    @ObservationIgnored private var pendingStarts: [UUID: Task<Void, Never>] = [:]
    /// Senaste stängningen. Varje stängning väntar även in den föregående, så när den här är klar är alla tidigare
    /// motorer stängda och deras leaser släppta.
    @ObservationIgnored private(set) var closeTask: Task<Void, Never>?
    /// Vyns ljudspärr (`setSoundEnabled`); profilens inställning gäller dessutom alltid.
    @ObservationIgnored private var soundAllowed = true

    init(dependencies: Dependencies) {
        self.deps = dependencies
        handle.controller = self
    }

    /// Säkerhetsnät om ägaren släpper kontrollern utan `stop()`: väntande starter avbryts (de skapar då ingen motor
    /// och släpper en sent beviljad lease själva), och det aktuella försöket stängs; leasen släpps efter motorn.
    isolated deinit {
        for task in pendingStarts.values { task.cancel() }
        if let a = current {
            current = nil
            finish(a)
        }
    }

    // MARK: - Fokus

    /// Fokus flyttades till `item` (nil = inget fokus). Föregående förhandsvisning tystnas, pausas och börjar
    /// stängas direkt (synkront); en ny start sker först när fokus stått still i `settleDelay`. Samma titel igen
    /// är en no-op.
    func focusChanged(to item: LibraryItem?, playlistID: UUID) {
        let key = item.map { FocusKey(playlistID: playlistID, itemID: $0.id) }
        if let key, key == focusedKey { return }
        focusedKey = key
        abandonCurrent()
        state = .idle
        guard let item, item.kind != .live else { return }
        if let reason = Self.verdict(deps) {
            state = .artwork(reason)
            return
        }
        let attempt = Attempt(item: item, playlistID: playlistID)
        current = attempt
        let previousClose = closeTask
        let id = attempt.id
        let deps = deps, handle = handle
        // Tasken håller bara `handle` (svag referens), aldrig kontrollern.
        let task = Task {
            await Self.run(attempt, handle: handle, deps: deps, previousClose: previousClose)
            handle.controller?.pendingStarts[id] = nil
        }
        attempt.task = task
        pendingStarts[id] = task
    }

    /// Stoppar förhandsvisningen helt (t.ex. när Hem försvinner) och väntar tills motorn stängts och leasen släppts.
    func stop() async {
        await stopNow().value
    }

    /// Som `stop()`, men själva stoppet sker synkront i anropet (försöket avslutas, motorn tystas och pausas) och
    /// bara väntan på stängningen returneras. En vy som försvinner kan därför stoppa direkt utan att ett senare
    /// fokus på en ny titel hinner före och sedan avbryts av ett försenat stopp. Väntan gäller bara det som
    /// fanns när stoppet gjordes, aldrig en start som kommer efteråt.
    @discardableResult
    func stopNow() -> Task<Void, Never> {
        focusedKey = nil
        abandonCurrent()
        state = .idle
        let starts = Array(pendingStarts.values)
        let closing = closeTask
        return Task {
            for task in starts { await task.value }
            await closing?.value
        }
    }

    /// Ljud i förhandsvisningen på/av från vyn (t.ex. tyst när ett blad visas). Ljud hörs bara om även profilens
    /// `previewSoundEnabled` är på.
    func setSoundEnabled(_ enabled: Bool) {
        soundAllowed = enabled
        if case .playing(let engine) = state { deps.setMuted(engine, !audible) }
    }

    private var audible: Bool { soundAllowed && deps.settings().previewSoundEnabled }

    // MARK: - Start

    /// Startar förhandsvisningen för `a`. Statisk och utan stark referens till kontrollern över suspensionspunkter:
    /// efter varje `await` prövas att kontrollern finns kvar och att försöket lever (`handle.live`), och bara då
    /// ändras läget, knyts en lease eller skapas en motor.
    private static func run(_ a: Attempt, handle: ControllerHandle, deps: Dependencies,
                            previousClose: Task<Void, Never>?) async {
        do { try await deps.sleep(settleDelay) } catch { return }
        guard handle.live(a) else { return }
        // Mäter från att fokus stått still tills motorn spelar (eller försöket fallit tillbaka/avbrutits).
        let interval = signposter.beginInterval("preview.start")
        defer { signposter.endInterval("preview.start", interval) }

        // Barnfiltret prövas före allt annat: en nekad titel begär aldrig någon ström.
        let kids = await deps.kidsAllowed(a.item, a.playlistID)
        if let reason = verdict(deps, kidsAllowed: kids) {
            handle.live(a) { $0.fallBack(a, reason) }
            return
        }
        guard handle.live(a, { c in
            c.state = .starting
            c.startWatchdog(a)
        }) else { return }

        guard let source = await deps.resolve(a.item, a.playlistID) else {
            handle.live(a) { $0.fallBack(a, nil) }
            return
        }
        if let reason = verdict(deps, container: source.containerExtension) {
            handle.live(a) { $0.fallBack(a, reason) }
            return
        }

        // Föregående förhandsvisnings anslutning ska vara släppt innan en ny begärs (max_connections == 1).
        await previousClose?.value
        guard handle.live(a) else { return }
        let lease = await deps.broker.acquirePreview(playlistID: a.playlistID) {
            await handle.revoke(a)
        }
        guard let lease else {
            handle.live(a) { $0.fallBack(a, verdict(deps, leaseGranted: false)) }
            return
        }
        // Ingen suspension mellan kontrollen och att leasen och motorn knyts till försöket: en stängning (även i
        // `deinit`) ser alltid båda och stänger motorn innan leasen släpps.
        var created: (any PlayerEngine)?
        let attached = handle.live(a) { _ in
            a.lease = lease
            let engine = deps.makeEngine()
            deps.setMuted(engine, true)
            a.engine = engine
            created = engine
        }
        guard attached, let engine = created else {
            // Avslutat (eller kontrollern borta) medan leasen begärdes. Ingen motor har skapats: släpp direkt.
            await deps.broker.release(lease)
            return
        }
        do {
            try await engine.load(url: source.url, startAt: PreviewPlan.startSeconds(duration: source.durationHint))
        } catch {
            let unsupported = (error as? PlaybackFailure) == .unsupportedFormat
            handle.live(a) { $0.fallBack(a, unsupported ? .unsupportedContainer : nil) }
            return
        }
        // Inte längre aktuellt: stängningen (fokusbyte, tidsgräns, revoke eller deinit) tar hand om motor och lease.
        handle.live(a) { c in c.didStartPlaying(a, engine: engine) }
    }

    private func didStartPlaying(_ a: Attempt, engine: any PlayerEngine) {
        a.reachedPlaying = true
        a.watchdog?.cancel()
        engine.onStateChange = { [weak self, weak a] newState in
            guard let self, let a else { return }
            switch newState {
            case .failed, .ended, .idle:
                if self.isLive(a) { self.fallBack(a, nil) }
            default:
                break
            }
        }
        deps.setMuted(engine, !audible)
        state = .playing(engine)
    }

    /// Har strömmen inte börjat spela inom `startTimeout` blir det artwork; motorn stängs och leasen släpps.
    private func startWatchdog(_ a: Attempt) {
        let sleep = deps.sleep
        a.watchdog = Task { [weak self, weak a] in
            guard (try? await sleep(PreviewController.startTimeout)) != nil else { return }
            guard let self, let a, self.isLive(a), !a.reachedPlaying else { return }
            self.fallBack(a, nil)
        }
    }

    /// Vakten vill ha anslutningen (t.ex. uppspelning på ett konto med en anslutning): stäng direkt och visa
    /// artwork. Leasen släpps inte här; vakten tar själv bort en återkallad lease.
    fileprivate func markRevoked(_ a: Attempt) {
        a.revoked = true
        if current === a {
            current = nil
            state = .artwork(.connectionBusy)
        }
        finish(a)
    }

    // MARK: - Stängning

    fileprivate func isLive(_ a: Attempt) -> Bool {
        !a.finished && current === a && !Task.isCancelled
    }

    private func abandonCurrent() {
        guard let a = current else { return }
        current = nil
        finish(a)
    }

    private func fallBack(_ a: Attempt, _ reason: PreviewFallback?) {
        if current === a {
            current = nil
            state = .artwork(reason)
        }
        finish(a)
    }

    /// Avslutar ett försök (idempotent). Synkront: start och tidsgräns avbryts, motorn tystnas och pausas. Sedan, i
    /// `closeTask`: motorn stängs med `closeAndWait()` och först därefter släpps leasen (inte om vakten återkallat
    /// den; då tar vakten själv bort den). En lease som beviljas efter avslutet släpps av starten själv, som då
    /// aldrig hunnit skapa någon motor. Stängningen håller inte kontrollern.
    @discardableResult
    private func finish(_ a: Attempt) -> Task<Void, Never> {
        if let existing = a.closeTask { return existing }
        a.finished = true
        a.task?.cancel()
        a.watchdog?.cancel()
        if let engine = a.engine {
            engine.onStateChange = nil
            deps.setMuted(engine, true)
            engine.pause()
        }
        let broker = deps.broker
        let previous = closeTask
        let task = Task { await Self.close(a, broker: broker, previous: previous) }
        a.closeTask = task
        closeTask = task
        return task
    }

    private static func close(_ a: Attempt, broker: any PreviewConnections, previous: Task<Void, Never>?) async {
        if let engine = a.engine { await engine.closeAndWait() }
        a.engine = nil
        if let lease = a.lease {
            a.lease = nil
            if !a.revoked { await broker.release(lease) }
        }
        await previous?.value
    }

    // MARK: - Beslut

    /// `PreviewEligibility.decide` med det som är känt hittills. Steg som inte prövats än räknas som godkända, så
    /// ett `.artwork`-beslut beror alltid på ett känt skäl och ordningen (`disabled`, `kidsDenied`,
    /// `unsupportedContainer`, `connectionBusy`) kommer från `PreviewEligibility`. Profilens inställning läses vid
    /// varje steg. `playbackActive` är alltid falskt: vakten exponerar inte syftena, så pågående uppspelning syns
    /// i stället som att leasen nekas (`connectionBusy`).
    private static func verdict(_ deps: Dependencies, kidsAllowed: Bool = true,
                                container: String? = notYetKnownContainer,
                                leaseGranted: Bool = true) -> PreviewFallback? {
        let decision = PreviewEligibility.decide(settingsEnabled: deps.settings().previewsEnabled,
                                                 kidsAllowed: kidsAllowed, container: container,
                                                 playbackActive: false, leaseGranted: leaseGranted)
        if case .artwork(let reason) = decision { return reason }
        return nil
    }

    /// Platshållare för en container som inte lästs än (räknas som spelbar tills den är känd).
    private static let notYetKnownContainer = "mp4"
}

/// Svag referens till kontrollern för asynkront arbete (starter och vaktens `onRevoke`).
@MainActor
private final class ControllerHandle {
    weak var controller: PreviewController?

    /// Kör `body` med kontrollern om den finns kvar och försöket fortfarande är aktuellt. Den starka referensen
    /// lever bara under anropet (ingen suspension).
    @discardableResult
    func live(_ a: Attempt, _ body: (PreviewController) -> Void = { _ in }) -> Bool {
        guard let controller, controller.isLive(a) else { return false }
        body(controller)
        return true
    }

    /// Vaktens återkallning: stänger försöket och returnerar först när motorn stängts. Finns kontrollern inte kvar
    /// har `deinit` redan börjat stänga försöket.
    func revoke(_ a: Attempt) async {
        a.revoked = true
        controller?.markRevoked(a)
        await a.closeTask?.value
    }
}

private struct FocusKey: Equatable {
    let playlistID: UUID
    let itemID: String
}

/// Ett försök att förhandsvisa en titel: start, motor, lease och stängning hör ihop.
@MainActor
private final class Attempt {
    let id = UUID()
    let item: LibraryItem
    let playlistID: UUID
    var engine: (any PlayerEngine)?
    var lease: StreamLease?
    /// Satt när försöket avslutats; därefter skapas ingen motor och ingen lease knyts till försöket.
    var finished = false
    var revoked = false
    var reachedPlaying = false
    var task: Task<Void, Never>?
    var watchdog: Task<Void, Never>?
    var closeTask: Task<Void, Never>?

    init(item: LibraryItem, playlistID: UUID) {
        self.item = item
        self.playlistID = playlistID
    }
}

/// Förhandsvisningen ändrar aldrig skärmens bildfrekvens eller dynamiska omfång (det skulle ge ett svart
/// lägesbyte på Apple TV vid varje fokus); det gör bara riktig uppspelning.
@MainActor
final class PreviewDisplayCriteria: DisplayCriteriaSetting {
    func criteria(for asset: AVAsset) async -> DisplayCriteria? { nil }
    func set(_ criteria: DisplayCriteria?) {}
}
