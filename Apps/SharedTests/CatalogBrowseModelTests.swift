import Core
import Foundation
import Library
import Testing
@testable import IPTVApp

private struct Boom: Error {}

private func item(_ id: String) -> Library.LibraryItem {
    Library.LibraryItem(kind: .movie, providerID: id, title: "Titel \(id)", year: nil, posterURL: nil)
}

private func items(_ count: Int) -> [Library.LibraryItem] {
    (0..<count).map { item("i\($0)") }
}

private func categories(_ names: String...) -> CatalogListing {
    .categories(names.enumerated().map {
        Core.Category(providerID: "c-\($1)", name: $1, kind: .movie, sortIndex: $0)
    })
}

/// Laddare som testet styr: anropet väntar tills `release`.
@MainActor
private final class GatedLoader {
    private(set) var calls = 0
    private(set) var limits: [Int] = []
    private(set) var waiting: CheckedContinuation<[Library.LibraryItem], Error>?

    func run(_ limit: Int) async throws -> [Library.LibraryItem] {
        calls += 1
        limits.append(limit)
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func release(_ result: [Library.LibraryItem]) {
        waiting?.resume(returning: result)
        waiting = nil
    }
}

@MainActor
struct CatalogBrowseModelTests {
    private func loaded(_ section: CatalogSection?) -> (items: [Library.LibraryItem], hasMore: Bool)? {
        guard case let .loaded(items, hasMore)? = section?.phase else { return nil }
        return (items, hasMore)
    }

    @Test func categoriesBecomeUnloadedSectionsInOrder() {
        let model = CatalogBrowseModel()
        model.configure(categories("A", "B", "C"))
        #expect(model.sections.map(\.title) == ["A", "B", "C"])
        #expect(model.sections.allSatisfy { $0.phase == .unloaded })
        #expect(model.sections.map(\.categoryID) == ["c-A", "c-B", "c-C"])
        #expect(model.sections.map(\.id) == ["cat:c-A", "cat:c-B", "cat:c-C"])
        #expect(model.menuEntries.count == 3)
    }

    @Test func loadStoresAtMostRowLimitAndFlagsMore() async throws {
        let model = CatalogBrowseModel()
        model.configure(categories("A", "B"))
        let gate = GatedLoader()
        let loader: CatalogBrowseModel.Loader = { _, limit in try await gate.run(limit) }

        let first = Task { await model.load(sectionID: "cat:c-A", using: loader) }
        while gate.waiting == nil { await Task.yield() }
        gate.release(items(21))
        await first.value
        let a = try #require(loaded(model.section(id: "cat:c-A")))
        #expect(a.items.count == 20 && a.hasMore)
        #expect(gate.limits == [21])

        let second = Task { await model.load(sectionID: "cat:c-B", using: loader) }
        while gate.waiting == nil { await Task.yield() }
        gate.release(items(20))
        await second.value
        let b = try #require(loaded(model.section(id: "cat:c-B")))
        #expect(b.items.count == 20 && !b.hasMore)
    }

    @Test func emptyCategoryIsHiddenFromMenu() async {
        let model = CatalogBrowseModel()
        model.configure(categories("A", "B"))
        await model.load(sectionID: "cat:c-A", using: { _, _ in [] })
        #expect(model.menuEntries.map(\.id) == ["cat:c-B"])
        #expect(model.sections.count == 2)
    }

    @Test func sameSectionIsNotLoadedTwice() async {
        let model = CatalogBrowseModel()
        model.configure(categories("A"))
        let gate = GatedLoader()
        let loader: CatalogBrowseModel.Loader = { _, limit in try await gate.run(limit) }

        let first = Task { await model.load(sectionID: "cat:c-A", using: loader) }
        while gate.waiting == nil { await Task.yield() }
        #expect(model.section(id: "cat:c-A")?.phase == .loading)
        await model.load(sectionID: "cat:c-A", using: loader)   // redan på väg: gör inget
        gate.release(items(3))
        await first.value
        #expect(gate.calls == 1)
        #expect(loaded(model.section(id: "cat:c-A"))?.items.count == 3)

        await model.load(sectionID: "cat:c-A", using: loader)   // redan laddad: gör inget
        #expect(gate.calls == 1)
    }

    @Test func failedOrCancelledLoadResetsToUnloaded() async throws {
        let model = CatalogBrowseModel()
        model.configure(categories("A"))
        await model.load(sectionID: "cat:c-A", using: { _, _ in throw Boom() })
        #expect(model.section(id: "cat:c-A")?.phase == .unloaded)
        await model.load(sectionID: "cat:c-A", using: { _, _ in throw CancellationError() })
        #expect(model.section(id: "cat:c-A")?.phase == .unloaded)

        await model.load(sectionID: "cat:c-A", using: { _, _ in items(2) })
        #expect(try #require(loaded(model.section(id: "cat:c-A"))).items.count == 2)
    }

    @Test func staleResponseAfterReconfigureIsDropped() async {
        let model = CatalogBrowseModel()
        model.configure(categories("A"))
        let gate = GatedLoader()
        let loader: CatalogBrowseModel.Loader = { _, limit in try await gate.run(limit) }

        let stale = Task { await model.load(sectionID: "cat:c-A", using: loader) }
        while gate.waiting == nil { await Task.yield() }
        model.configure(categories("A"))
        gate.release(items(5))
        await stale.value
        #expect(model.section(id: "cat:c-A")?.phase == .unloaded)
    }

    @Test func kidsRowsAreLoadedAndNeverHaveMore() async throws {
        let model = CatalogBrowseModel()
        let full = HomeRow(id: .genre(1, .movie), title: "Barnfilmer", titles: items(30))
        let empty = HomeRow(id: .genre(2, .movie), title: "Tom")
        model.configure(.kids([full, empty]))
        #expect(model.sections.count == 1)
        let section = try #require(model.sections.first)
        #expect(section.categoryID == nil && section.title == "Barnfilmer")
        let state = try #require(loaded(section))
        #expect(state.items.count == 30 && !state.hasMore)

        let gate = GatedLoader()
        await model.load(sectionID: section.id, using: { _, limit in try await gate.run(limit) })
        #expect(gate.calls == 0)
        #expect(loaded(model.section(id: section.id))?.items.count == 30)
    }

    @Test func firstItemIDRequiresLoadedSection() async {
        let model = CatalogBrowseModel()
        model.configure(categories("A"))
        #expect(model.firstItemID(inSection: "cat:c-A") == nil)
        #expect(model.firstItemID(inSection: "saknas") == nil)
        await model.load(sectionID: "cat:c-A", using: { _, _ in items(3) })
        #expect(model.firstItemID(inSection: "cat:c-A") == item("i0").id)
    }
}
