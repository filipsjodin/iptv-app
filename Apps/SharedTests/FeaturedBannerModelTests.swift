#if !os(tvOS)
import Core
import Discovery
import Foundation
import Library
import Testing
@testable import IPTVApp

private func item(_ kind: ContentKind, _ id: String) -> Library.LibraryItem {
    Library.LibraryItem(kind: kind, providerID: id, title: "T\(id)", year: nil, posterURL: nil)
}

private func row(_ id: RowID, _ titles: [Library.LibraryItem]) -> HomeRow {
    HomeRow(id: id, title: "R", titles: titles)
}

struct FeaturedPickerTests {
    @Test func picksFirstForYouTitle() {
        let rows = [row(.topTen(.movie), [item(.movie, "t1")]),
                    row(.forYou, [item(.movie, "f1"), item(.series, "f2")])]
        #expect(FeaturedPicker.pick(from: rows)?.item.providerID == "f1")
    }

    @Test func fallsBackToFirstNonContinueRow() {
        let rows = [HomeRow(id: .continueWatching, title: "C"),
                    row(.recentlyAdded(.series), [item(.series, "r1")]),
                    row(.topTen(.movie), [item(.movie, "t1")])]
        #expect(FeaturedPicker.pick(from: rows)?.item.providerID == "r1")
    }

    @Test func skipsEmptyRowsAndLive() {
        let rows = [row(.forYou, []),
                    row(.topTen(.movie), [item(.live, "l1")]),
                    row(.myList, [item(.live, "l2"), item(.movie, "m1")])]
        #expect(FeaturedPicker.pick(from: rows)?.item.providerID == "m1")
    }

    @Test func nilWhenNoRows() {
        #expect(FeaturedPicker.pick(from: []) == nil)
        #expect(FeaturedPicker.pick(from: [HomeRow(id: .continueWatching, title: "C"), row(.forYou, [])]) == nil)
    }

    @Test func picksSeveralTitlesFromTheSameRowSkippingLive() {
        let rows = [row(.topTen(.movie), [item(.movie, "t1")]),
                    row(.forYou, [item(.movie, "f1"), item(.live, "l1"), item(.series, "f2"), item(.movie, "f3")])]
        #expect(FeaturedPicker.picks(from: rows, limit: 2).map(\.item.providerID) == ["f1", "f2"])
        #expect(FeaturedPicker.picks(from: rows, limit: 10).map(\.item.providerID) == ["f1", "f2", "f3"])
        #expect(FeaturedPicker.picks(from: rows, limit: 1) == [FeaturedPicker.pick(from: rows)].compactMap { $0 })
        #expect(FeaturedPicker.picks(from: rows, limit: 0).isEmpty)
        #expect(FeaturedPicker.picks(from: [], limit: 5).isEmpty)
    }

    @Test func kidsRowsOnlyContainAllowedTitles() {
        // Väljaren väljer bara ur raderna den får; en åldersfiltrerad (här: tom) rad ger ingen banner.
        let allowed = [row(.forYou, [item(.movie, "kid1")])]
        #expect(FeaturedPicker.pick(from: allowed)?.item.providerID == "kid1")
        #expect(FeaturedPicker.pick(from: [row(.forYou, [])]) == nil)
    }
}
#endif
