import Testing
import Foundation
import Core
@testable import Providers

private func ls(_ id: String, _ name: String, epg: String? = nil, category: String? = "c") -> LiveStream {
    LiveStream(providerID: id, name: name, categoryID: category, epgChannelID: epg, locator: .template("{server}/\(id)"))
}

@Test func matchesByEpgChannelIDFirst() {
    let g = ChannelGrouper.group([ls("1", "SE: TV4 HD", epg: "tv4.se")])
    let m = EPGMatcher.match(groups: g, xmltvChannels: [])
    #expect(m[g[0].id] == "tv4.se")
}

@Test func fallsBackToNormalizedName() {
    let g = ChannelGrouper.group([ls("1", "SVT1 HD")])
    let m = EPGMatcher.match(groups: g, xmltvChannels: [EPGChannel(id: "svt1.se", names: ["SVT 1"])])
    #expect(m[g[0].id] == "svt1.se")
}

@Test func epgIDWinsOverNameWhenBothExist() {
    let g = ChannelGrouper.group([ls("1", "SVT1 HD", epg: "mine")])
    let m = EPGMatcher.match(groups: g, xmltvChannels: [EPGChannel(id: "other", names: ["SVT 1"])])
    #expect(m[g[0].id] == "mine")
}

@Test func twoGroupsMayShareOneXmltvID() {
    let g = ChannelGrouper.group([ls("1", "SE: TV4 HD", category: "a"), ls("2", "SE: TV4 HD", category: "b")])
    #expect(g.count == 2)
    let m = EPGMatcher.match(groups: g, xmltvChannels: [EPGChannel(id: "tv4.se", names: ["TV4"])])
    #expect(m[g[0].id] == "tv4.se")
    #expect(m[g[1].id] == "tv4.se")
}

@Test func unmatchedGroupIsAbsent() {
    let g = ChannelGrouper.group([ls("1", "Okänd Kanal")])
    let m = EPGMatcher.match(groups: g, xmltvChannels: [EPGChannel(id: "x", names: ["Annan"])])
    #expect(m[g[0].id] == nil)
    #expect(m.isEmpty)
}

@Test func firstXmltvChannelWinsOnDuplicateNames() {
    let g = ChannelGrouper.group([ls("1", "TV4 HD")])
    let m = EPGMatcher.match(groups: g, xmltvChannels: [EPGChannel(id: "a", names: ["TV4"]), EPGChannel(id: "b", names: ["TV 4"])])
    #expect(m[g[0].id] == "a")
}

@Test func splitProviderIDBecomesOwnGroup() {
    let g = ChannelGrouper.group([ls("1", "SE: TV4 HD"), ls("2", "SE: TV4 FHD")], splitProviderIDs: ["1"])
    #expect(g.count == 2)
    let split = g.first { $0.id.hasSuffix("\u{1F}split\u{1F}1") }!
    #expect(split.variants.map(\.providerID) == ["1"])
    #expect(split.displayName == "TV4")
    #expect(split.preferred(displaySupportsHDR: true).providerID == "1")
}

@Test func splitGroupKeepsRemainingVariantsTogether() {
    let plain = ChannelGrouper.group([ls("1", "SE: TV4 HD"), ls("2", "SE: TV4 FHD"), ls("3", "SE: TV4 4K")])
    let g = ChannelGrouper.group([ls("1", "SE: TV4 HD"), ls("2", "SE: TV4 FHD"), ls("3", "SE: TV4 4K")], splitProviderIDs: ["2"])
    let rest = g.first { $0.id == plain[0].id }!
    #expect(rest.variants.map(\.providerID) == ["3", "1"])
    #expect(rest.preferred(displaySupportsHDR: false).providerID == "3")
    let split = g.first { $0.id == plain[0].id + "\u{1F}split\u{1F}2" }!
    #expect(split.variants.map(\.providerID) == ["2"])
}

@Test func noSplitsEqualsPlainGrouping() {
    let streams = [ls("1", "SE: TV4 HD"), ls("2", "SE: TV4 4K"), ls("3", "SVT1 HD")]
    let a = ChannelGrouper.group(streams)
    let b = ChannelGrouper.group(streams, splitProviderIDs: [])
    #expect(a.map(\.id) == b.map(\.id))
    #expect(a.map { $0.variants.map(\.providerID) } == b.map { $0.variants.map(\.providerID) })
}
