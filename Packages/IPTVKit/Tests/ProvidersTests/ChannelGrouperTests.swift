import Testing
import Foundation
import Core
@testable import Providers

private func ls(_ id: String, _ name: String, category: String? = "c", logo: URL? = nil) -> LiveStream {
    LiveStream(providerID: id, name: name, categoryID: category, logoURL: logo, locator: .template("{server}/\(id)"))
}

@Test func groupsVariantsAndPrefersBest() {
    let g = ChannelGrouper.group([ls("1","SE: TV4 HD"), ls("2","SE: TV4 4K HDR"), ls("3","SE: TV4 FHD"), ls("4","UK: TV4 HD"), ls("5","SE: SVT1 HD")])
    #expect(g.count == 3)
    let tv4 = g.first { $0.displayName == "TV4" && $0.variants.count == 3 }!
    #expect(tv4.preferred(displaySupportsHDR: true).providerID == "2")
    #expect(tv4.preferred(displaySupportsHDR: false).providerID == "3")  // FHD SDR före 4K HDR på SDR-skärm
}

@Test func idsAreUniqueAcrossCountriesAndCategories() {
    let g = ChannelGrouper.group([ls("1","SE: TV4 HD"), ls("2","UK: TV4 HD"), ls("3","SE: TV4 HD", category: "d")])
    #expect(g.count == 3)
    #expect(Set(g.map(\.id)).count == 3)
}

@Test func preservesFirstSeenOrderAndSortsVariantsBestFirst() {
    let g = ChannelGrouper.group([ls("1","SE: SVT1 HD"), ls("2","SE: TV4 SD"), ls("3","SE: SVT1 4K"), ls("4","SE: TV4 FHD")])
    #expect(g.map(\.displayName) == ["SVT1", "TV4"])
    #expect(g[0].variants.map(\.providerID) == ["3", "1"])
    #expect(g[1].variants.map(\.providerID) == ["4", "2"])
}

@Test func logoIsFirstNonNilAmongBestFirstVariants() {
    let logo = URL(string: "https://x/logo.png")!
    let g = ChannelGrouper.group([ls("1","SE: TV4 HD", logo: logo), ls("2","SE: TV4 4K")])
    #expect(g[0].variants.first?.providerID == "2")
    #expect(g[0].logoURL == logo)
}

@Test func sdrDisplayRanksHDRAfterAllSDR() {
    let g = ChannelGrouper.group([ls("1","TV4 4K HDR"), ls("2","TV4 SD")])
    #expect(g[0].preferred(displaySupportsHDR: false).providerID == "2")
    #expect(g[0].preferred(displaySupportsHDR: true).providerID == "1")
}

@Test func tieBreakIsDeterministicByProviderID() {
    let a = ChannelGrouper.group([ls("b","TV4 HD"), ls("a","TV4 HD")])
    let b = ChannelGrouper.group([ls("a","TV4 HD"), ls("b","TV4 HD")])
    #expect(a[0].preferred(displaySupportsHDR: true).providerID == "a")
    #expect(b[0].preferred(displaySupportsHDR: true).providerID == "a")
}

@Test func emptyInputGivesNoGroups() {
    #expect(ChannelGrouper.group([]).isEmpty)
}
