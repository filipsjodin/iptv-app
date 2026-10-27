import AVFoundation
import Foundation
import Library
import Observation
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
    /// Fokus är stillastående; strömmen förbereds eller laddas.
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

/// Äger förhandsvisningens livscykel: en tyst ström ur titelns egen spellista som startar när fokus stått still i
/// 1,5 s och stängs direkt när fokus flyttas (§6.5).
///
/// Anslutningen tas från `StreamConnectionBroker` med syftet `.preview`. Förhandsvisningar får bara en ledig plats
/// och tränger därför aldrig undan uppspelning; uppspelning kan däremot återkalla förhandsvisningen (`onRevoke`),
/// som då stängs direkt och faller tillbaka till artwork. Leasen släpps alltid först **efter** att motorn stängts
/// (`closeAndWait`), exakt en gång, oavsett om starten avbröts, tog för lång tid, misslyckades eller återkallades.
@MainActor @Observable
final class PreviewController {
    /// Allt kontrollern behöver utifrån; tester skickar testmotorer, en testklocka och en egen vakt.
    struct Dependencies {
        var broker: StreamConnectionBroker
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
        if let reason = verdict() {
            state = .artwork(reason)
            return
        }
        let attempt = Attempt(item: item, playlistID: playlistID)
        current = attempt
        let previousClose = closeTask
        let id = attempt.id
        let task = Task { [weak self] in
            await self?.run(attempt, previousClose: previousClose)
            self?.pendingStarts[id] = nil
        }
        attempt.task = task
        pendingStarts[id] = task
    }

    /// Stoppar förhandsvisningen helt (t.ex. när Hem försvinner) och väntar tills motorn stängts och leasen släppts.
    func stop() async {
        focusedKey = nil
        abandonCurrent()
        state = .idle
        for task in Array(pendingStarts.values) { await task.value }
        await closeTask?.value
    }

    /// Ljud i förhandsvisningen på/av från vyn (t.ex. tyst när ett blad visas). Ljud hörs bara om även profilens
    /// `previewSoundEnabled` är på.
    func setSoundEnabled(_ enabled: Bool) {
        soundAllowed = enabled
        if case .playing(let engine) = state { deps.setMuted(engine, !audible) }
    }

    private var audible: Bool { soundAllowed && deps.settings().previewSoundEnabled }

    // MARK: - Start

    private func run(_ a: Attempt, previousClose: Task<Void, Never>?) async {
        do { try await deps.sleep(Self.settleDelay) } catch { return }
        guard isLive(a) else { return }
        state = .starting
        startWatchdog(a)

        // Barnfiltret prövas före allt annat: en nekad titel begär aldrig någon ström.
        let kids = await deps.kidsAllowed(a.item, a.playlistID)
        guard isLive(a) else { return }
        if let reason = verdict(kidsAllowed: kids) { return fallBack(a, reason) }

        guard let source = await deps.resolve(a.item, a.playlistID) else {
            guard isLive(a) else { return }
            return fallBack(a, nil)
        }
        guard isLive(a) else { return }
        if let reason = verdict(container: source.containerExtension) { return fallBack(a, reason) }

        // Föregående förhandsvisnings anslutning ska vara släppt innan en ny begärs (max_connections == 1).
        await previousClose?.value
        guard isLive(a) else { return }
        let lease = await deps.broker.acquire(.preview, playlistID: a.playlistID) { [weak self] in
            await self?.revoke(a)
        }
        guard let lease else {
            guard isLive(a) else { return }
            return fallBack(a, verdict(leaseGranted: false))
        }
        guard isLive(a) else {
            // Avbruten medan leasen begärdes. Ingen motor har skapats, så platsen kan släppas direkt.
            await deps.broker.release(lease)
            return
        }
        // Ingen suspension mellan kontrollen ovan och att leasen och motorn knyts till försöket: en stängning ser
        // alltid båda (och stänger motorn innan leasen släpps).
        a.lease = lease
        let engine = deps.makeEngine()
        deps.setMuted(engine, true)
        a.engine = engine
        do {
            try await engine.load(url: source.url, startAt: PreviewPlan.startSeconds(duration: source.durationHint))
        } catch {
            guard isLive(a) else { return }
            let unsupported = (error as? PlaybackFailure) == .unsupportedFormat
            return fallBack(a, unsupported ? .unsupportedContainer : nil)
        }
        guard isLive(a) else { return }
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
    /// artwork. Returnerar först när motorn stängts, så att vakten inte delar ut platsen för tidigt.
    private func revoke(_ a: Attempt) async {
        a.revoked = true
        if current === a {
            current = nil
            state = .artwork(.connectionBusy)
        }
        await finish(a).value
    }

    // MARK: - Stängning

    private func isLive(_ a: Attempt) -> Bool {
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
    /// aldrig hunnit skapa någon motor.
    @discardableResult
    private func finish(_ a: Attempt) -> Task<Void, Never> {
        if let existing = a.closeTask { return existing }
        a.finished = true
        a.task?.cancel()
        a.watchdog?.cancel()
        let engine = a.engine
        if let engine {
            engine.onStateChange = nil
            deps.setMuted(engine, true)
            engine.pause()
        }
        let broker = deps.broker
        let previous = closeTask
        let task = Task {
            if let engine { await engine.closeAndWait() }
            a.engine = nil
            if let lease = a.lease {
                a.lease = nil
                if !a.revoked { await broker.release(lease) }
            }
            await previous?.value
        }
        a.closeTask = task
        closeTask = task
        return task
    }

    // MARK: - Beslut

    /// `PreviewEligibility.decide` med det som är känt hittills. Steg som inte prövats än räknas som godkända, så
    /// ett `.artwork`-beslut beror alltid på ett känt skäl och ordningen (`disabled`, `kidsDenied`,
    /// `unsupportedContainer`, `connectionBusy`) kommer från `PreviewEligibility`. Profilens inställning läses vid
    /// varje steg. `playbackActive` är alltid falskt: vakten exponerar inte syftena, så pågående uppspelning syns
    /// i stället som att leasen nekas (`connectionBusy`).
    private func verdict(kidsAllowed: Bool = true, container: String? = PreviewController.notYetKnownContainer,
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
