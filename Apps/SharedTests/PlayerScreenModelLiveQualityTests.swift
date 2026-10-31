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
                           configure: Bool = true, hdr: Bool = true, gate: CloseGate? = nil,
                           observePlaying: Bool = true) async -> PlayerScreenModel {
        let first = makeSession(request(current), log: log, closeGate: gate)
        await first.start()
        let model = PlayerScreenModel(session: first, nextEpisodeProvider: nil,
                                      makeSession: { makeSession($0, log: log) },
                                      setIdleTimerDisabled: { _ in }, now: { clock.date })
        if configure {
            model.configureLive(groups: [group], current: current, displaySupportsHDR: hdr,
                                request: { _, stream in self.request(stream.providerID) })
            // Modellen har sett strömmen spela, så nästa buffring är ett riktigt stannande.
            if observePlaying { model.observeBuffering() }
        }
        return model
    }

    /// Ett buffringsstopp: motorn buffrar och återhämtar sig, och modellen får se båda lägena.
    private func stall(_ model: PlayerScreenModel, clock: Clock, advance: TimeInterval = 5) {
        model.tick()   // ser eventuell uppspelning före stannandet
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

    /// Väntar (begränsat) tills `condition` blir sann; misslyckas i stället för att hänga.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        #expect(condition(), "\(what)")
    }

    @Test func selectingVariantKeepsLeaseAndNeverOpensTwoStreams() async {
        let broker = StreamConnectionBroker()
        let log = EventLog()
        let gate = CloseGate()
        let first = makeSession(request("v4k"), log: log, closeGate: gate)
        let model = PlayerScreenModel(session: first, nextEpisodeProvider: nil,
                                      makeSession: { makeSession($0, log: log) }, setIdleTimerDisabled: { _ in },
                                      broker: broker, playlistID: playlistID)
        model.configureLive(groups: [group()], current: "v4k", displaySupportsHDR: true,
                            request: { _, stream in self.request(stream.providerID) })
        await model.start()
        let lease = model.lease
        // Det första valet står i `stopAndWait` (grinden håller kvar stängningen) när det andra kommer.
        let a = Task { await model.selectVariant("vhd") }
        await waitUntil("första valet når stängningen") { gate.entered >= 1 }
        let b = Task { await model.selectVariant("vsd") }
        for _ in 0..<20 { await Task.yield() }   // det andra valet hinner ersätta det första
        #expect(log.events == ["load"])           // inget nytt öppnat medan stängningen hålls
        gate.open()
        await a.value
        await b.value
        #expect(model.lease === lease)
        #expect(await broker.activeCount(playlistID: playlistID) == 1)
        #expect(model.currentVariantID == "vsd")
        #expect(log.events.filter { $0 == "load" }.count == 2)   // exakt en ny ström
        #expect(log.events.last == "load")
        model.stop()
        await model.closeTask?.value
        #expect(await broker.activeCount(playlistID: playlistID) == 0)
    }

    @Test func zapSupersedesInFlightQualitySwitch() async {
        let log = EventLog()
        let gate = CloseGate()
        let model = await makeModel(group: group(), current: "v4k", log: log, clock: Clock(), gate: gate)
        let variant = Task { await model.selectVariant("vhd") }
        await waitUntil("kvalitetsbytet når stängningen") { gate.entered >= 1 }
        let zap = Task { await model.switchChannel(to: request("other")) }
        for _ in 0..<20 { await Task.yield() }
        gate.open()
        await variant.value
        #expect(await zap.value)
        // Zappningen vann: strömmen är kanalbytets, kvalitetsbytet öppnade ingenting.
        #expect(model.currentVariantID == "other")
        #expect(log.events.filter { $0 == "load" }.count == 2)
        #expect(log.events.last == "load")
    }

    @Test func noRequestMeansNoSwitch() async {
        // Barnläge: begäran byggs inte (nil), då rörs varken strömmen eller valet.
        let log = EventLog()
        let model = await makeModel(group: group(), current: "v4k", log: log, clock: Clock(), configure: false)
        model.configureLive(groups: [group()], current: "v4k", displaySupportsHDR: true, request: { _, _ in nil })
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
        // Gäller även när bannern tonat ut på tvOS: vyn anropar då `dismissSuggestion()`.
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

    // MARK: - HDR-skärm

    private func hdrGroup() -> ChannelGroup {
        group(names: [("vfhd", "SE: TV4 FHD"), ("vhdr", "SE: TV4 HD HDR"), ("vsd", "SE: TV4 SD")])
    }

    @Test func sdrDisplayHidesHDRVariantsAndSuggestsNextAllowed() async {
        let clock = Clock()
        let model = await makeModel(group: hdrGroup(), current: "vfhd", log: EventLog(), clock: clock, hdr: false)
        #expect(model.liveVariants.map(\.id) == ["vfhd", "vsd"])
        #expect(model.menus.first { $0.id == "quality" }?.options.map(\.id) == ["quality.vfhd", "quality.vsd"])
        for _ in 0..<3 { stall(model, clock: clock) }
        #expect(model.suggestLower?.id == "vsd")
    }

    @Test func sdrDisplayCannotSelectHDRVariant() async {
        let log = EventLog()
        let model = await makeModel(group: hdrGroup(), current: "vfhd", log: log, clock: Clock(), hdr: false)
        await model.selectVariant("vhdr")
        #expect(log.events == ["load"])
        #expect(model.currentVariantID == "vfhd")
    }

    @Test func hdrDisplayOffersAllVariantsInOrder() async {
        let clock = Clock()
        let model = await makeModel(group: hdrGroup(), current: "vfhd", log: EventLog(), clock: clock, hdr: true)
        #expect(model.liveVariants.map(\.id) == ["vfhd", "vhdr", "vsd"])
        for _ in 0..<3 { stall(model, clock: clock) }
        #expect(model.suggestLower?.id == "vhdr")
    }

    @Test func sdrDisplayWithOnlyOneSDRVariantHasNoQualityMenu() async {
        let g = group(names: [("vhdr", "SE: TV4 HD HDR"), ("vsd", "SE: TV4 SD")])
        let hdrModel = await makeModel(group: g, current: "vhdr", log: EventLog(), clock: Clock(), hdr: true)
        #expect(hdrModel.liveVariants.count == 2)
        let sdr = await makeModel(group: g, current: "vsd", log: EventLog(), clock: Clock(), hdr: false)
        #expect(sdr.liveVariants.isEmpty)
        #expect(!sdr.menus.contains { $0.id == "quality" })
    }

    // MARK: - Riktiga stannanden

    @Test func bufferingBeforeFirstPlayDoesNotCount() async {
        let clock = Clock()
        let model = await makeModel(group: group(), current: "v4k", log: EventLog(), clock: clock,
                                    observePlaying: false)
        // Uppstartsbuffringen (innan modellen sett strömmen spela) räknas inte.
        let engine = model.session.engine as? TestEngine
        engine?.emit(.buffering)
        model.tick()
        engine?.emit(.playing)
        model.tick()
        stall(model, clock: clock)
        stall(model, clock: clock)
        #expect(model.suggestLower == nil)
        stall(model, clock: clock)
        #expect(model.suggestLower?.id == "vhd")
    }

    @Test func resumeAfterPauseDoesNotCount() async {
        let clock = Clock()
        let model = await makeModel(group: group(), current: "v4k", log: EventLog(), clock: clock)
        stall(model, clock: clock)
        stall(model, clock: clock)
        let engine = model.session.engine as? TestEngine
        engine?.emit(.paused)
        model.tick()
        engine?.emit(.buffering)   // återupptagning efter paus
        model.tick()
        engine?.emit(.playing)
        model.tick()
        #expect(model.suggestLower == nil)
        stall(model, clock: clock)
        #expect(model.suggestLower?.id == "vhd")
    }

    @Test func engineSwapRestartsWithoutCountingStartup() async {
        let clock = Clock()
        let model = await makeModel(group: group(), current: "v4k", log: EventLog(), clock: clock)
        stall(model, clock: clock)
        stall(model, clock: clock)
        await model.switchEngine(to: .vlc)   // ny motor; dess uppstart är inget stannande
        let engine = model.session.engine as? TestEngine
        engine?.emit(.buffering)
        model.tick()
        engine?.emit(.playing)
        model.tick()
        #expect(model.suggestLower == nil)
    }
}
