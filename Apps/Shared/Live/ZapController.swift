import Core
import Foundation
import Observation
import Playback
import Providers

/// Zappning mellan kanaler i spelaren: upp/ned i listan (runt vid kanterna), där listan är den som Live-fliken
/// visade när spelaren öppnades.
///
/// Bara sista begäran vinner: varje `zap` ersätter det pågående bytet (en enda `Task`). Ett byte som ännu inte
/// startat avbryts direkt; ett som redan påbörjats avbryts via `Task`-avbrytning och `switchTo` ska då inte öppna
/// någon ström. Nästa byte väntar in det föregående innan det börjar, så att aldrig två strömmar är öppna samtidigt
/// (konton med en enda anslutning). `switchTo` ansvarar för att stänga föregående session med `stopAndWait` innan
/// nästa öppnas. Allt körs på huvudaktören; ingen nätverks- eller databasåtkomst här.
@MainActor @Observable
final class ZapController {
    enum Direction { case up, down }

    /// Kanalen som är vald just nu (uppdateras direkt vid `zap`, även om strömmen ännu inte hunnit byta).
    private(set) var current: ChannelGroup

    @ObservationIgnored private let groups: [ChannelGroup]
    @ObservationIgnored private let request: @MainActor (ChannelGroup) -> PlaybackRequest?
    @ObservationIgnored private let switchTo: @MainActor (PlaybackRequest) async -> Bool
    @ObservationIgnored private let started: @MainActor (ChannelGroup) -> Void
    @ObservationIgnored private let settle: Duration
    @ObservationIgnored private var index: Int
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Satt av `cancel()` (spelaren stängs): inga fler byten.
    @ObservationIgnored private var closed = false

    /// - Parameters:
    ///   - groups: kanalerna i den ordning användaren ser dem. Får inte vara tom; `start` som saknas ger första.
    ///   - start: grupp-id för kanalen som spelas nu.
    ///   - request: bygger uppspelningsbegäran; `nil` (barnläge, ingen profil, saknad hemlighet) ger inget byte.
    ///   - switchTo: stänger föregående session och öppnar nästa; ska avbryta tyst om tasken avbryts. Returnerar
    ///     om den nya strömmen faktiskt startades.
    ///   - started: anropas bara när `switchTo` startat kanalen (inte för avbrutna eller misslyckade byten).
    ///   - settle: kort väntan innan strömmen byts, så att snabba tryck bara ger ett byte. `.zero` i tester.
    init(groups: [ChannelGroup], start: String,
         request: @escaping @MainActor (ChannelGroup) -> PlaybackRequest?,
         switchTo: @escaping @MainActor (PlaybackRequest) async -> Bool,
         started: @escaping @MainActor (ChannelGroup) -> Void = { _ in },
         settle: Duration = .milliseconds(250)) {
        precondition(!groups.isEmpty, "ZapController kräver minst en kanal")
        let start = groups.firstIndex { $0.id == start } ?? 0
        self.groups = groups
        self.request = request
        self.switchTo = switchTo
        self.started = started
        self.settle = settle
        index = start
        current = groups[start]
    }

    /// Upp = föregående kanal i listan, ned = nästa. Runt vid kanterna.
    /// Returnerar om ett byte schemalagts (inte vid en enda kanal, utan begäran eller efter `cancel()`).
    @discardableResult
    func zap(_ direction: Direction) -> Bool {
        guard groups.count > 1 else { return false }
        let step = direction == .up ? -1 : 1
        return select((index + step + groups.count) % groups.count)
    }

    /// Byter till kanalen med givet grupp-id; okänt id ignoreras.
    @discardableResult
    func zapTo(_ groupID: String) -> Bool {
        guard let target = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        return select(target)
    }

    /// Avbryter ett pågående byte när spelaren stängs och tar emot inga fler. Referensen behålls, så att
    /// `settled()` (och en eventuell senare kedja) fortfarande väntar in ett avbrutet byte som håller på att stänga
    /// sin ström; aldrig två strömmar öppna.
    func cancel() {
        closed = true
        task?.cancel()
    }

    /// Väntar tills alla begärda byten är klara (för tester).
    func settled() async {
        await task?.value
    }

    private func select(_ target: Int) -> Bool {
        guard !closed else { return false }
        let group = groups[target]
        // Utan begäran (barnläge m.m.) rörs varken valet eller strömmen.
        guard let request = request(group) else { return false }
        index = target
        current = group
        let previous = task
        previous?.cancel()
        task = Task { [weak self] in
            // Det föregående bytet avslutas (och stänger sin ström) innan nästa får öppna något.
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            if self.settle > .zero {
                do { try await Task.sleep(for: self.settle) } catch { return }
            }
            guard !Task.isCancelled else { return }
            guard await self.switchTo(request), !Task.isCancelled else { return }
            self.started(group)
        }
        return true
    }
}

/// Vad spelaren behöver för att zappa: kanallistan i användarens ordning, startkanalen och hur begäran och
/// "Nu/Nästa" hämtas. Skickas med `PlayerPresentation` från Live-fliken; bara live har en.
struct LiveZapContext {
    let groups: [ChannelGroup]
    let start: String
    /// Bygger begäran för en kanal (nil i barnläge m.m.).
    let request: @MainActor (ChannelGroup) -> PlaybackRequest?
    /// Läser pågående och nästa program för kanalen (kan ta tid; blockerar inte zappningen).
    let nowNext: @MainActor (ChannelGroup) async -> NowNext?
    /// Noterar att kanalen startat (Senast sedda).
    let noteWatched: @MainActor (ChannelGroup) -> Void
    /// Profilens favoriter och senast sedda (nyast först); används bara av kanalbytaren på iOS.
    var favoriteIDs: Set<String> = []
    var recentIDs: [String] = []
}
