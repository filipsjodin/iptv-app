import Core
import Foundation
import Playback
import PlaybackCore
import Providers
import Testing
@testable import IPTVApp

/// Kvalitetsmenyn och buffringsförslaget för live. Allt går direkt mot modellen med en lokal motor (`TestEngine`);
/// inga väntetider, så inget test kan hänga.
@MainActor
struct PlayerScreenModelLiveQualityTests {
    private let playlistID = UUID()

    /// Tre varianter av samma kanal (4K, HD, SD) i en grupp, bäst först: v4k, vhd, vsd.
    private func group(names: [(String, String)] = [("v4k", "SE: TV4 4K"), ("vhd", "SE: TV4 HD"),
                                                      ("vsd", "SE: TV4 SD")]) -> ChannelGroup {
        let streams = names.map { LiveStream(providerID: $0.0, name: $0.1, categoryID: "c",
                                             locator: .template("{server}/\($0.0)")) }
        return ChannelGrouper.group(streams)[0]
    }

    private func request(_ providerID: String) -> PlaybackRequest {
        PlaybackRequest(key: ProgressKey(playlistID: playlistID, kind: .live, providerID: providerID),
                        title: providerID, locator: .template("{server}/\(providerID)"), container: nil, isLive: true)
    }

    /// Klocka som stegas manuellt.
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
    }

    private func makeModel(group: ChannelGroup, current: String, log: EventLog, clock: Clock,
                           configure: Bool = true) async -> PlayerScreenModel {
        let first = makeSession(request(current), log: log)
        await first.start()
        let model = PlayerScreenModel(session: first, nextEpisodeProvider: nil,
                                      makeSession: { makeSession($0, log: log) },
                                      setIdleTimerDisabled: { _ in }, now: { clock.date })
        if configure {
            model.configureLive(groups: [group], current: current,
                                request: { _, stream in self.request(stream.providerID) })
        }
        return model
    }

    /// Ett buffringsstopp: motorn buffrar och återhämtar sig, och modellen får se båda lägena.
    private func stall(_ model: PlayerScreenModel, clock: Clock, advance: TimeInterval = 5) {
        let engine = model.session.engine as? TestEngine
        engine?.emit(.buffering)
        model.tick()
        engine?.emit(.playing)
        model.tick()
        clock.advance(advance)
    }

    @Test func variantsListedBestFirstWithCurrentMarked() async {
        let model = await makeModel(group: group(), current: "vhd", log: EventLog(), clock: Clock())
        #expect(model.liveVariants.map(\.id) == ["v4k", "vhd", "vsd"])
        #expect(model.liveVariants.map(\.isCurrent) == [false, true, false])
        let quality = model.menus.first { $0.id == "quality" }
        #expect(quality?.options.map(\.id) == ["quality.v4k", "quality.vhd", "quality.vsd"])
        #expect(quality?.options.map(\.isSelected) == [false, true, false])
    }

    @Test func qualityMenuOnlyForLiveWithTwoOrMoreVariants() async {
        let single = group(names: [("only", "SE: SVT1 HD")])
        let model = await makeModel(group: single, current: "only", log: EventLog(), clock: Clock())
        #expect(model.liveVariants.isEmpty)
        #expect(!model.menus.contains { $0.id == "quality" })
        // Utan live-konfiguration (film, avsnitt, barnläge) finns ingen kvalitetsmeny.
        let vod = await makeModel(group: group(), current: "vhd", log: EventLog(), clock: Clock(), configure: false)
        #expect(vod.liveVariants.isEmpty)
        #expect(!vod.menus.contains { $0.id == "quality" })
    }

    @Test func selectingVariantSwitchesStreamViaStopAndWait() async {
        let log = EventLog()
        let model = await makeModel(group: group(), current: "v4k", log: log, clock: Clock())
        let first = model.session
        await model.selectVariant("vhd")
        #expect(log.events == ["load", "closedAndWaited", "load"])
        #expect(model.session !== first)
        #expect(first.engine == nil)
        #expect(model.currentVariantID == "vhd")
        #expect(model.liveVariants.map(\.isCurrent) == [false, true, false])
        // Samma variant igen och okänd variant gör ingenting.
        await model.selectVariant("vhd")
        await model.selectVariant("saknas")
        #expect(log.events == ["load", "closedAndWaited", "load"])
    }

    @Test func selectingVariantKeepsLeaseAndNeverOpensTwoStreams() async {
        let broker = StreamConnectionBroker()
        let log = EventLog()
        let first = makeSession(request("v4k"), log: log)
        let model = PlayerScreenModel(session: first, nextEpisodeProvider: nil,
                                      makeSession: { makeSession($0, log: log) }, setIdleTimerDisabled: { _ in },
                                      broker: broker, playlistID: playlistID)
        model.configureLive(groups: [group()], current: "v4k", request: { _, stream in self.request(stream.providerID) })
        await model.start()
        let lease = model.lease
        // Två val i följd (det andra medan det första väntar) ger exakt en ny ström åt gången.
        async let a: Void = model.selectVariant("vhd")
        async let b: Void = model.selectVariant("vsd")
        _ = await (a, b)
        #expect(model.lease === lease)
        #expect(await broker.activeCount(playlistID: playlistID) == 1)
        // Bara det första valet öppnade en ny ström; det andra såg att ett byte redan pågick.
        #expect(log.events.filter { $0 == "load" }.count == 2)
        #expect(log.events.last == "load")
        #expect(model.currentVariantID == "vhd")
        model.stop()
        await model.closeTask?.value
        #expect(await broker.activeCount(playlistID: playlistID) == 0)
    }

    @Test func noRequestMeansNoSwitch() async {
        // Barnläge: begäran byggs inte (nil), då rörs varken strömmen eller valet.
        let log = EventLog()
        let model = await makeModel(group: group(), current: "v4k", log: log, clock: Clock(), configure: false)
        model.configureLive(groups: [group()], current: "v4k", request: { _, _ in nil })
        await model.selectVariant("vhd")
        #expect(log.events == ["load"])
        #expect(model.currentVariantID == "v4k")
    }

    @Test func threeStallsSuggestNextLowerVariant() async {
        let clock = Clock()
        let model = await makeModel(group: group(), current: "v4k", log: EventLog(), clock: clock)
        stall(model, clock: clock)
        stall(model, clock: clock)
        #expect(model.suggestLower == nil)
        stall(model, clock: clock)
        #expect(model.suggestLower?.id == "vhd")
        #expect(model.suggestLower?.quality == VariantQuality(quality: .hd, isHDR: false))
    }

    @Test func acceptingSuggestionSwitchesAndClearsIt() async {
        let clock = Clock()
        let log = EventLog()
        let model = await makeModel(group: group(), current: "v4k", log: log, clock: clock)
        for _ in 0..<3 { stall(model, clock: clock) }
        await model.acceptSuggestion()
        #expect(model.suggestLower == nil)
        #expect(model.currentVariantID == "vhd")
        #expect(log.events == ["load", "closedAndWaited", "load"])
    }

    @Test func noSuggestionWhenAlreadyLowest() async {
        let clock = Clock()
        let model = await makeModel(group: group(), current: "vsd", log: EventLog(), clock: clock)
        for _ in 0..<6 { stall(model, clock: clock) }
        #expect(model.suggestLower == nil)
    }

    @Test func dismissedSuggestionNotShownAgain() async {
        let clock = Clock()
        let model = await makeModel(group: group(), current: "v4k", log: EventLog(), clock: clock)
        for _ in 0..<3 { stall(model, clock: clock) }
        #expect(model.suggestLower != nil)
        model.dismissSuggestion()
        #expect(model.suggestLower == nil)
        for _ in 0..<6 { stall(model, clock: clock) }
        #expect(model.suggestLower == nil)
    }

    @Test func channelSwitchResetsStallHistory() async {
        let clock = Clock()
        let model = await makeModel(group: group(), current: "v4k", log: EventLog(), clock: clock)
        stall(model, clock: clock)
        stall(model, clock: clock)
        #expect(await model.switchChannel(to: request("vhd")))
        // Det tredje stannandet räknas från noll efter bytet.
        stall(model, clock: clock)
        #expect(model.suggestLower == nil)
    }

    @Test func stallsOutsideWindowDoNotSuggest() async {
        let clock = Clock()
        let model = await makeModel(group: group(), current: "v4k", log: EventLog(), clock: clock)
        for _ in 0..<5 { stall(model, clock: clock, advance: 40) }
        #expect(model.suggestLower == nil)
    }

    @Test func hidingSuggestionDoesNotRememberDismissal() async {
        let clock = Clock()
        let model = await makeModel(group: group(), current: "v4k", log: EventLog(), clock: clock)
        for _ in 0..<3 { stall(model, clock: clock) }
        model.hideSuggestion()
        #expect(model.suggestLower == nil)
        for _ in 0..<3 { stall(model, clock: clock) }
        #expect(model.suggestLower?.id == "vhd")
    }
}
