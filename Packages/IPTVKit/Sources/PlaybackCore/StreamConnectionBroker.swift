import Foundation

/// Syfte för en strömanslutning. Högre värde = högre prioritet.
public enum StreamPurpose: Int, Comparable, Sendable {
    case download = 0, preview = 1, playback = 2

    public static func < (lhs: StreamPurpose, rhs: StreamPurpose) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// En tilldelad anslutningsplats i en spellista.
public final class StreamLease: Sendable {
    public let id: UUID
    public let purpose: StreamPurpose
    public let playlistID: UUID

    init(id: UUID = UUID(), purpose: StreamPurpose, playlistID: UUID) {
        self.id = id
        self.purpose = purpose
        self.playlistID = playlistID
    }
}

/// Fördelar en spellistas begränsade antal samtidiga strömanslutningar mellan
/// uppspelning, förhandsvisningar och nedladdningar.
///
/// - Uppspelning får alltid en plats: vid full gräns återkallas först nedladdningar
///   (äldst först), sedan förhandsvisningar (äldst först), sist den äldsta uppspelningen.
/// - Förhandsvisning och nedladdning får en plats bara om den är ledig, annars `nil`.
/// - En lease som håller på att återkallas upptar sin plats tills dess `onRevoke`
///   returnerat (eller tidsgränsen löpt ut). Varje lease återkallas högst en gång.
/// - Okänd gräns (`nil`) behandlas som 1.
public actor StreamConnectionBroker {
    private struct Entry {
        let lease: StreamLease
        let seq: UInt64
        let onRevoke: @Sendable () async -> Void
        var revoking: Bool
    }

    private struct PlaylistState {
        var limit: Int?
        var entries: [UUID: Entry] = [:]
        /// Uppspelningar som väntar på att en pågående återkallning ska bli klar.
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private var states: [UUID: PlaylistState] = [:]
    private var nextSeq: UInt64 = 0
    private let revokeTimeout: Duration

    /// - Parameter revokeTimeout: hur länge en `onRevoke` får ta innan platsen ändå
    ///   betraktas som ledig, så att uppspelning aldrig blockeras för evigt.
    public init(revokeTimeout: Duration = .seconds(5)) {
        self.revokeTimeout = revokeTimeout
    }

    public func setLimit(_ limit: Int?, playlistID: UUID) {
        states[playlistID, default: PlaylistState()].limit = limit
    }

    /// Antal upptagna platser (inklusive leasingar som håller på att återkallas).
    public func activeCount(playlistID: UUID) -> Int {
        states[playlistID]?.entries.count ?? 0
    }

    public func acquire(
        _ purpose: StreamPurpose,
        playlistID: UUID,
        onRevoke: @escaping @Sendable () async -> Void
    ) async -> StreamLease? {
        if purpose != .playback {
            let state = states[playlistID, default: PlaylistState()]
            // Lediga platser som väntande uppspelningar ska ha tas inte av lägre syften.
            guard state.entries.count < effectiveLimit(state), state.waiters.isEmpty else { return nil }
            return grant(purpose, playlistID: playlistID, onRevoke: onRevoke)
        }

        while true {
            let state = states[playlistID, default: PlaylistState()]
            if state.entries.count < effectiveLimit(state) {
                return grant(purpose, playlistID: playlistID, onRevoke: onRevoke)
            }
            if let victim = pickVictim(state) {
                // Markera i samma actor-tur som valet → ingen annan kan välja samma lease.
                states[playlistID]?.entries[victim.lease.id]?.revoking = true
                await Self.runRevoke(victim.onRevoke, timeout: revokeTimeout)
                states[playlistID]?.entries[victim.lease.id] = nil
                // Ta platsen direkt (utan suspension) innan väntare väcks, så att
                // utfallet blir deterministiskt: den som återkallade får platsen.
                let current = states[playlistID, default: PlaylistState()]
                let lease: StreamLease? = current.entries.count < effectiveLimit(current)
                    ? grant(purpose, playlistID: playlistID, onRevoke: onRevoke)
                    : nil
                wakeWaiters(playlistID)
                if let lease { return lease }
                continue
            }
            // Alla platser återkallas redan av andra; vänta tills någon blir klar.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                states[playlistID, default: PlaylistState()].waiters.append(c)
            }
        }
    }

    /// Släpper en lease. Okänd eller redan släppt lease är en no-op. En lease som
    /// håller på att återkallas tas bort av återkallaren när `onRevoke` returnerat.
    public func release(_ lease: StreamLease) {
        guard let entry = states[lease.playlistID]?.entries[lease.id], !entry.revoking else { return }
        states[lease.playlistID]?.entries[lease.id] = nil
        wakeWaiters(lease.playlistID)
    }

    // MARK: - Privat

    private func effectiveLimit(_ state: PlaylistState) -> Int {
        max(1, state.limit ?? 1)
    }

    private func grant(
        _ purpose: StreamPurpose,
        playlistID: UUID,
        onRevoke: @escaping @Sendable () async -> Void
    ) -> StreamLease {
        let lease = StreamLease(purpose: purpose, playlistID: playlistID)
        nextSeq &+= 1
        states[playlistID, default: PlaylistState()].entries[lease.id] =
            Entry(lease: lease, seq: nextSeq, onRevoke: onRevoke, revoking: false)
        return lease
    }

    /// Nedladdningar först, sedan förhandsvisningar, sist uppspelningar; äldst först inom syftet.
    private func pickVictim(_ state: PlaylistState) -> Entry? {
        state.entries.values
            .filter { !$0.revoking }
            .min { ($0.lease.purpose.rawValue, $0.seq) < ($1.lease.purpose.rawValue, $1.seq) }
    }

    private func wakeWaiters(_ playlistID: UUID) {
        guard let waiters = states[playlistID]?.waiters, !waiters.isEmpty else { return }
        states[playlistID]?.waiters = []
        for w in waiters { w.resume() }
    }

    /// Kör `revoke` men returnerar senast efter `timeout`, även om `revoke` aldrig blir klar.
    private static func runRevoke(_ revoke: @escaping @Sendable () async -> Void, timeout: Duration) async {
        let gate = ResumeOnce()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gate.install(c)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                gate.resume()
            }
            Task {
                await revoke()
                timer.cancel()
                gate.resume()
            }
        }
    }
}

/// Återupptar en continuation exakt en gång, oavsett vem som hinner först.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func install(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if resumed { lock.unlock(); c.resume(); return }
        continuation = c
        lock.unlock()
    }

    func resume() {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
