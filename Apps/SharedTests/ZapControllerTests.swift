import Foundation
import Playback
import Providers
import Testing
@testable import IPTVApp

private func channels(_ names: [String]) -> [ChannelGroup] {
    ChannelGrouper.group(names.enumerated().map { index, name in
        LiveStream(providerID: "\(index + 1)", name: name, categoryID: "A", epgChannelID: nil,
                   locator: .xtream(kind: .live, streamID: "\(index + 1)", container: "ts"))
    })
}

private func liveRequest(_ group: ChannelGroup) -> PlaybackRequest {
    PlaybackRequest(key: ProgressKey(playlistID: UUID(), kind: .live, providerID: group.id),
                    title: group.displayName, locator: .xtream(kind: .live, streamID: group.id, container: "ts"),
                    container: "ts", isLive: true)
}

/// Fake för sessionsbytet: loggar "close" (föregående ström släpps) och "open" (nästa öppnas) med en valfri grind
/// mellan dem, så att överlappande byten kan styras utan sömn.
@MainActor
private final class Switcher {
    private(set) var log: [String] = []
    private(set) var opened: [String] = []
    /// När satt väntar bytet här efter "close" (simulerar en ström som tar tid att släppa).
    var gate: AsyncStream<Void>.Continuation?
    private var gateStream: AsyncStream<Void>?
    private(set) var started = false

    func holdNextClose() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        gateStream = stream
        gate = continuation
    }

    func release() {
        gate?.yield()
        gate?.finish()
        gate = nil
    }

    func switchTo(_ request: PlaybackRequest) async {
        log.append("close")
        if let stream = gateStream {
            gateStream = nil
            started = true
            for await _ in stream { break }
        }
        // Som `PlayerScreenModel.switchChannel`: avbruten efter stängningen betyder att inget öppnas.
        guard !Task.isCancelled else { log.append("cancelled"); return }
        log.append("open")
        opened.append(request.title)
    }
}

@MainActor
private final class NameLog {
    var names: [String] = []
}

@MainActor
private func makeController(_ names: [String], start: String, switcher: Switcher,
                            request: @escaping @MainActor (ChannelGroup) -> PlaybackRequest? = { liveRequest($0) },
                            started: @escaping @MainActor (ChannelGroup) -> Void = { _ in }) -> (ZapController, [ChannelGroup]) {
    let groups = channels(names)
    let id = groups.first { $0.displayName == start }!.id
    let controller = ZapController(groups: groups, start: id, request: request,
                                   switchTo: { await switcher.switchTo($0) }, started: started, settle: .zero)
    return (controller, groups)
}

@MainActor
struct ZapControllerTests {
    @Test func zapUpDownWrapsAround() async {
        let switcher = Switcher()
        let (zap, _) = makeController(["Alfa", "Beta", "Gamma"], start: "Alfa", switcher: switcher)
        zap.zap(.up)
        #expect(zap.current.displayName == "Gamma")
        await zap.settled()
        zap.zap(.down)
        #expect(zap.current.displayName == "Alfa")
        await zap.settled()
        zap.zap(.down)
        zap.zap(.down)
        zap.zap(.down)
        #expect(zap.current.displayName == "Alfa")
        await zap.settled()
        #expect(switcher.opened.last == "Alfa")
    }

    @Test func rapidZapsOnlySwitchToLast() async {
        let switcher = Switcher()
        let (zap, _) = makeController(["A", "B", "C", "D", "E", "F"], start: "A", switcher: switcher)
        for _ in 0..<5 { zap.zap(.down) }
        await zap.settled()
        #expect(switcher.opened == ["F"])
        #expect(switcher.log == ["close", "open"])
    }

    @Test func previousSessionClosedBeforeNextOpens() async {
        let switcher = Switcher()
        let (zap, _) = makeController(["A", "B", "C"], start: "A", switcher: switcher)
        zap.zap(.down)
        await zap.settled()
        zap.zap(.down)
        await zap.settled()
        #expect(switcher.log == ["close", "open", "close", "open"])
        #expect(switcher.opened == ["B", "C"])
    }

    @Test func zapToUnknownIDIsIgnored() async {
        let switcher = Switcher()
        let (zap, _) = makeController(["A", "B"], start: "A", switcher: switcher)
        zap.zapTo("finns-inte")
        await zap.settled()
        #expect(zap.current.displayName == "A")
        #expect(switcher.log.isEmpty)
    }

    @Test func zapToKnownIDSwitches() async {
        let switcher = Switcher()
        let (zap, groups) = makeController(["A", "B", "C"], start: "A", switcher: switcher)
        zap.zapTo(groups[2].id)
        await zap.settled()
        #expect(zap.current.displayName == "C")
        #expect(switcher.opened == ["C"])
    }

    @Test func kidsProfileCannotZap() async {
        let switcher = Switcher()
        let (zap, _) = makeController(["A", "B"], start: "A", switcher: switcher, request: { _ in nil })
        zap.zap(.down)
        zap.zap(.up)
        zap.zapTo("irrelevant")
        await zap.settled()
        #expect(zap.current.displayName == "A")
        #expect(switcher.log.isEmpty)
    }

    @Test func lastWinsUnderOverlappingAsyncSwitch() async {
        let switcher = Switcher()
        let startedLog = NameLog()
        let (zap, _) = makeController(["A", "B", "C"], start: "A", switcher: switcher,
                                      started: { startedLog.names.append($0.displayName) })
        switcher.holdNextClose()
        zap.zap(.down)   // B: påbörjas och hänger efter "close"
        while !switcher.started { await Task.yield() }
        zap.zap(.down)   // C: ersätter B medan B:s ström ännu släpps
        switcher.release()
        await zap.settled()
        // B öppnas aldrig; C öppnas först efter att B:s stängning avslutats.
        #expect(switcher.opened == ["C"])
        #expect(switcher.log == ["close", "cancelled", "close", "open"])
        #expect(startedLog.names == ["C"])
    }

    @Test func cancelledSwitchLeavesNoHalfStartedState() async {
        let switcher = Switcher()
        let startedLog = NameLog()
        let (zap, _) = makeController(["A", "B"], start: "A", switcher: switcher,
                                      started: { startedLog.names.append($0.displayName) })
        switcher.holdNextClose()
        zap.zap(.down)
        while !switcher.started { await Task.yield() }
        zap.cancel()
        switcher.release()
        await Task.yield()
        #expect(switcher.opened.isEmpty)
        #expect(startedLog.names.isEmpty)
        // Kontrollern kan användas igen efter avbrottet.
        zap.zap(.up)
        await zap.settled()
        #expect(switcher.opened == ["A"])
        #expect(startedLog.names == ["A"])
    }
}
