import Testing
@testable import IPTVApp

private let entries = [
    CatalogMenuEntry(id: "a", title: "A"),
    CatalogMenuEntry(id: "b", title: "B"),
    CatalogMenuEntry(id: "c", title: "C"),
]

struct CatalogMenuStateTests {
    @Test func opensOnOriginSection() {
        var state = CatalogMenuState()
        state.open(from: "b", entries: entries)
        #expect(state.isOpen)
        #expect(state.focusedEntryID == "b")
    }

    @Test func fallsBackToFirstEntryWhenOriginMissing() {
        var state = CatalogMenuState()
        state.open(from: "saknas", entries: entries)
        #expect(state.isOpen)
        #expect(state.focusedEntryID == "a")

        var fromNil = CatalogMenuState()
        fromNil.open(from: nil, entries: entries)
        #expect(fromNil.focusedEntryID == "a")
    }

    @Test func emptyEntriesDoNotOpen() {
        var state = CatalogMenuState()
        state.open(from: "a", entries: [])
        #expect(!state.isOpen)
        #expect(state.focusedEntryID == nil)
    }

    @Test func selectKeepsMenuOpenAndFocusInMenu() {
        var state = CatalogMenuState()
        state.open(from: "a", entries: entries)
        state.select("b")
        #expect(state.isOpen)
        #expect(state.focusedEntryID == "b")
        #expect(state.selectedSectionID == "b")
    }

    @Test func closeReturnsLastSelected() {
        var state = CatalogMenuState()
        state.open(from: "b", entries: entries)
        state.select("a")
        state.select("c")
        #expect(state.close() == "c")
        #expect(!state.isOpen)
    }

    @Test func closeWithoutSelectionReturnsOrigin() {
        var state = CatalogMenuState()
        state.open(from: "b", entries: entries)
        #expect(state.close() == "b")
        #expect(!state.isOpen)
    }

    @Test func closeResetsSelection() {
        var state = CatalogMenuState()
        state.open(from: "b", entries: entries)
        state.select("c")
        #expect(state.close() == "c")
        state.open(from: "a", entries: entries)
        #expect(state.selectedSectionID == nil)
        #expect(state.close() == "a")
    }
}
