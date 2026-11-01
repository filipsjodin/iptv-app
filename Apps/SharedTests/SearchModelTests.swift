#if !os(tvOS)
import Core
import Foundation
import Library
import Testing
@testable import IPTVApp

/// Styrbar sökning till `SearchModel`: räknar anrop och spelar in `kids`-flaggan. Ingen databas.
@MainActor
final class SearchStub {
    var results: [String: [Library.LibraryItem]] = [:]
    var error: (any Error)?
    /// Fördröjning (ms) per fråga; sover utan att respektera avbrott.
    var delays: [String: Int] = [:]
    var kids = false
    /// Körs när sökningen har startat (före fördröjningen).
    var onStart: (@MainActor () -> Void)?
    private(set) var queries: [String] = []
    private(set) var kidsFlags: [Bool] = []

    func run(_ query: String, _ kids: Bool) async throws -> [Library.LibraryItem] {
        queries.append(query)
        kidsFlags.append(kids)
        onStart?()
        if let ms = delays[query] { _ = try? await Task.sleep(for: .milliseconds(ms)) }
        if let error { throw error }
        return results[query] ?? []
    }

    func makeModel() -> SearchModel {
        SearchModel(playlistID: UUID(),
                    search: { @Sendable [self] q, k in try await run(q, k) },
                    kids: { [self] in kids })
    }
}

private struct Boom: Error {}

private func item(_ kind: ContentKind, _ id: String) -> Library.LibraryItem {
    Library.LibraryItem(kind: kind, providerID: id, title: "T\(id)", year: nil, posterURL: nil)
}

@MainActor
@Suite struct SearchModelTests {
    @Test func emptyQueryIsIdleAndDoesNotSearch() async {
        let stub = SearchStub()
        let model = stub.makeModel()
        model.query = "   "
        await model.queryChanged()
        #expect(model.phase == .idle)
        #expect(stub.queries.isEmpty)
    }

    @Test func resultsAreSplitIntoMoviesAndSeries() async {
        let stub = SearchStub()
        let m = item(.movie, "1"), s = item(.series, "2"), l = item(.live, "3")
        stub.results["a"] = [m, l, s]
        let model = stub.makeModel()
        model.query = "a"
        await model.queryChanged()
        #expect(model.phase == .results(movies: [m], series: [s]))
    }

    @Test func kidsFlagIsPassedToSearch() async {
        let stub = SearchStub()
        stub.kids = true
        stub.results["a"] = [item(.movie, "1")]
        let model = stub.makeModel()
        model.query = "a"
        await model.queryChanged()
        #expect(stub.kidsFlags == [true])
    }

    @Test func kidsFlagIsReReadAfterAwait() async {
        let stub = SearchStub()
        stub.results["a"] = [item(.movie, "1")]
        stub.onStart = { [stub] in stub.kids = true }   // profilen byts till barn medan sökningen pågår
        let model = stub.makeModel()
        model.query = "a"
        await model.queryChanged()
        #expect(stub.kidsFlags == [false])
        #expect(model.phase == .empty)
    }

    @Test func newQueryCancelsPreviousSearch() async {
        let stub = SearchStub()
        let old = item(.movie, "old"), new = item(.series, "new")
        stub.results["a"] = [old]
        stub.results["ab"] = [new]
        stub.delays["a"] = 400
        let model = stub.makeModel()
        model.query = "a"
        let first = Task { await model.queryChanged() }
        for _ in 0..<200 where stub.queries.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(stub.queries == ["a"])
        model.query = "ab"
        await model.queryChanged()
        await first.value
        #expect(model.phase == .results(movies: [], series: [new]))
    }

    @Test func noResultsGivesEmpty() async {
        let stub = SearchStub()
        let model = stub.makeModel()
        model.query = "zzz"
        await model.queryChanged()
        #expect(model.phase == .empty)
    }

    @Test func failureGivesFailed() async {
        let stub = SearchStub()
        stub.error = Boom()
        let model = stub.makeModel()
        model.query = "a"
        await model.queryChanged()
        #expect(model.phase == .failed)
    }
}
#endif
