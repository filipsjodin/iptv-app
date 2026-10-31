import Foundation
import Testing
@testable import PlaybackCore

@Test func iPhonePortraitGetsThreeOrFourColumns() {
    let columns = LayoutMetrics(availableWidth: 390).columns
    #expect(columns == 3)
}

@Test func iPadFullWidthGetsManyColumns() {
    #expect(LayoutMetrics(availableWidth: 1024).columns >= 6)
}

@Test func narrowSplitViewKeepsAtLeastTwoColumns() {
    #expect(LayoutMetrics(availableWidth: 320).columns == 2)
}

@Test func posterWidthIsClamped() {
    // Mycket smalt: golvet 100. Två kolumner på 429 med stor text: taket 180.
    #expect(LayoutMetrics(availableWidth: 100).posterWidth == 100)
    #expect(LayoutMetrics(availableWidth: 429, dynamicTypeScale: 1.5).posterWidth == 180)
    for width in stride(from: 200.0, through: 2000.0, by: 37.0) {
        let w = LayoutMetrics(availableWidth: width).posterWidth
        #expect(w >= 100 && w <= 180)
    }
}

@Test func largeDynamicTypeRemovesOneColumn() {
    let normal = LayoutMetrics(availableWidth: 390)
    let large = LayoutMetrics(availableWidth: 390, dynamicTypeScale: 1.5)
    #expect(large.columns == normal.columns - 1)
    #expect(LayoutMetrics(availableWidth: 390, dynamicTypeScale: 1.3).columns == normal.columns) // gränsen exklusiv
    // Aldrig under två.
    #expect(LayoutMetrics(availableWidth: 320, dynamicTypeScale: 2).columns == 2)
}

@Test func isRegularThreshold() {
    #expect(!LayoutMetrics(availableWidth: 699.9).isRegular)
    #expect(LayoutMetrics(availableWidth: 700).isRegular)
}

@Test(arguments: [0, -50, Double.nan, Double.infinity, -Double.infinity] as [Double])
func zeroOrNegativeWidthDoesNotCrash(width: Double) {
    let m = LayoutMetrics(availableWidth: width)
    #expect(m.columns >= 2)
    #expect(m.posterWidth >= 100 && m.posterWidth <= 180)
}
