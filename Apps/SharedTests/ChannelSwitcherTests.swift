#if !os(tvOS)
import Core
import Foundation
import Playback
import PlaybackCore
import Providers
import Testing
@testable import IPTVApp

@MainActor
private func channels(_ names: [String]) -> [ChannelGroup] {
    ChannelGrouper.group(names.enumerated().map { index, name in
        LiveStream(providerID: "\(index + 1)", name: name, categoryID: "A", epgChannelID: nil,
                   locator: .xtream(kind: .live, streamID: "\(index + 1)", container: "ts"))
    })
}

@MainActor
private func zapContext(_ groups: [ChannelGroup], start: String? = nil) -> LiveZapContext {
    LiveZapContext(groups: groups, start: start ?? groups[0].id, request: { _ in nil }, nowNext: { _ in nil },
                   noteWatched: { _ in })
}

@MainActor
private final class Chosen {
    var ids: [String] = []
}

@MainActor
private func request(_ providerID: String) -> PlaybackRequest {
    PlaybackRequest(key: ProgressKey(playlistID: UUID(), kind: .live, providerID: providerID), title: providerID,
                    locator: .template("{server}/\(providerID)"), container: nil, isLive: true)
}

@MainActor
@Suite("ChannelSwitcher")
struct ChannelSwitcherTests {
    @Test func sectionsMatchZapListOrder() {
        let groups = channels(["Ett", "Två", "Tre", "Fyra"])
        let ids = groups.map(\.id)
        let model = ChannelSwitcherModel(groups: groups, currentID: ids[0],
                                         favoriteIDs: [ids[3], ids[1]], recentIDs: [ids[2], ids[3], "okänd", ids[2]],
                                         select: { _ in })
        #expect(model.sections.map(\.id) == ["favorites", "recents", "all"])
        // Favoriter och alla i zapplistans ordning; Senast sedda nyast först, utan dubbletter och okända.
        #expect(model.sections[0].groups.map(\.id) == [ids[1], ids[3]])
        #expect(model.sections[1].groups.map(\.id) == [ids[2], ids[3]])
        #expect(model.sections[2].groups.map(\.id) == ids)
    }

    @Test func emptyFavoritesAndRecentsAreOmitted() {
        let groups = channels(["Ett", "Två"])
        let model = ChannelSwitcherModel(groups: groups, currentID: groups[0].id, select: { _ in })
        #expect(model.sections.map(\.id) == ["all"])
    }

    @Test func chooseCallsSelectOnce() {
        let groups = channels(["Ett", "Två", "Tre"])
        let chosen = Chosen()
        let model = ChannelSwitcherModel(groups: groups, currentID: groups[0].id, select: { chosen.ids.append($0.id) })
        model.choose(groups[2])
        #expect(chosen.ids == [groups[2].id])
    }

    @Test func chooseCurrentIsIgnored() {
        let groups = channels(["Ett", "Två"])
        let chosen = Chosen()
        let model = ChannelSwitcherModel(groups: groups, currentID: groups[1].id, select: { chosen.ids.append($0.id) })
        model.choose(groups[1])
        #expect(chosen.ids.isEmpty)
    }

    @Test func chooseSwitchesThroughZapControllerAndKeepsCurrentInSync() async {
        let groups = channels(["Ett", "Två", "Tre"])
        let opened = Chosen()
        let zapper = ZapController(groups: groups, start: groups[0].id, request: { request($0.id) },
                                   switchTo: { opened.ids.append($0.key.providerID); return true }, settle: .zero)
        let model = ChannelSwitcherModel(groups: groups, currentID: zapper.current.id,
                                         select: { _ = zapper.zapTo($0.id) })
        model.choose(groups[2])
        await zapper.settled()
        #expect(zapper.current.id == groups[2].id)
        #expect(opened.ids == [groups[2].id])
    }

    @Test func switcherAbsentForKids() {
        let groups = channels(["Ett", "Två"])
        #expect(ChannelSwitcherModel.isAvailable(isLive: true, kidsRestricted: false, zap: zapContext(groups)))
        #expect(!ChannelSwitcherModel.isAvailable(isLive: true, kidsRestricted: true, zap: zapContext(groups)))
    }

    @Test func switcherAbsentWithoutZapContext() {
        let groups = channels(["Ett", "Två"])
        #expect(!ChannelSwitcherModel.isAvailable(isLive: true, kidsRestricted: false, zap: nil))
        #expect(!ChannelSwitcherModel.isAvailable(isLive: false, kidsRestricted: false, zap: zapContext(groups)))
        #expect(!ChannelSwitcherModel.isAvailable(isLive: true, kidsRestricted: false,
                                                  zap: zapContext([groups[0]])))
    }

    @Test func channelsMenuOnlyWhenConfigured() async {
        let groups = channels(["Ett", "Två"])
        let log = EventLog()
        let session = makeSession(request(groups[0].id), log: log)
        await session.start()
        let model = PlayerScreenModel(session: session, nextEpisodeProvider: nil,
                                      makeSession: { makeSession($0, log: log) }, setIdleTimerDisabled: { _ in })
        #expect(!model.menus.contains { $0.id == "channels" })
        model.configureChannelSwitcher {
            ChannelSwitcherModel(groups: groups, currentID: groups[0].id, select: { _ in })
        }
        let menu = model.menus.first { $0.id == "channels" }
        #expect(menu != nil)
        menu?.options.first?.action?()
        #expect(model.channelSwitcherPresented)
        model.dismissChannelSwitcher()
        #expect(!model.channelSwitcherPresented)
    }
}
#endif
