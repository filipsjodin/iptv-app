import Foundation
import Library
import Subtitles
import Testing
@testable import IPTVApp

/// Styrbar bakgrund till sökmodellen: räknar anrop och returnerar det testet ställt in. Inget nätverk, ingen databas.
@MainActor
final class SearchBackendStub {
    var loggedIn = true
    var results: [OpenSubtitlesResult] = []
    var searchError: (any Error)?
    var downloadError: (any Error)?
    var stored = StoredSubtitle(id: 11, language: "sv", release: "Rel", addedAt: Date(timeIntervalSince1970: 0),
                                fileURL: URL(fileURLWithPath: "/tmp/11.srt"))
    var quota: OpenSubtitlesQuota? = OpenSubtitlesQuota(remaining: 9, allowed: 10)
    var downloadQuota = OpenSubtitlesQuota(remaining: 8, allowed: 10)
    private(set) var refreshCalls = 0
    private(set) var searchCalls = 0
    private(set) var downloadCalls = 0

    var backend: SubtitleSearchBackend {
        SubtitleSearchBackend(
            refreshLogin: { [self] in refreshCalls += 1 },
            isLoggedIn: { [self] in loggedIn },
            search: { [self] in
                searchCalls += 1
                if let searchError { throw searchError }
                return results
            },
            download: { [self] _ in
                downloadCalls += 1
                if let downloadError { throw downloadError }
                return (stored, downloadQuota)
            },
            quota: { [self] in quota })
    }
}

func osResult(_ id: Int, language: String = "sv", rating: Double = 5, downloads: Int = 100) -> OpenSubtitlesResult {
    OpenSubtitlesResult(id: id, language: language, release: "Rel\(id)", fileName: "\(id).srt", rating: rating,
                        downloadCount: downloads, hearingImpaired: false, aiTranslated: false)
}

@MainActor
struct SubtitleSearchModelTests {
    private func makeModel(_ stub: SearchBackendStub, languages: [String] = ["sv", "en"],
                           onDownloaded: @escaping @MainActor (StoredSubtitle) async -> Void = { _ in })
        -> SubtitleSearchModel
    {
        SubtitleSearchModel(backend: stub.backend, preferredLanguages: languages, onDownloaded: onDownloaded)
    }

    @Test func searchSortsAndShowsResults() async {
        let stub = SearchBackendStub()
        // Osorterat in: engelska med högst betyg, svenska med lägre och högre betyg.
        let en = osResult(1, language: "en", rating: 9)
        let svLow = osResult(2, language: "sv", rating: 3)
        let svHigh = osResult(3, language: "sv", rating: 7)
        stub.results = [en, svLow, svHigh]
        let model = makeModel(stub)
        #expect(model.phase == .idle)

        await model.search()

        // Förvalda språk först (sv före en), därefter betyg.
        #expect(model.phase == .results([svHigh, svLow, en]))
        #expect(model.quota == OpenSubtitlesQuota(remaining: 9, allowed: 10))
        #expect(stub.refreshCalls == 1)
    }

    @Test func emptyResultShowsEmptyPhase() async {
        let stub = SearchBackendStub()
        let model = makeModel(stub)
        await model.search()
        #expect(model.phase == .empty)
    }

    @Test func quotaExhaustedShowsQuotaFailureWithResetTime() async {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let stub = SearchBackendStub()
        stub.searchError = OpenSubtitlesError.quotaExhausted(resetAt: reset)
        let model = makeModel(stub)
        await model.search()
        #expect(model.phase == .failed(.quota(resetAt: reset)))

        // Samma vid nedladdning: kvoten tar slut när texten hämtas.
        let second = SearchBackendStub()
        second.results = [osResult(1)]
        second.downloadError = OpenSubtitlesError.quotaExhausted(resetAt: nil)
        let other = makeModel(second)
        await other.search()
        await other.download(osResult(1))
        #expect(other.phase == .failed(.quota(resetAt: nil)))
    }

    @Test func notLoggedInShowsLoginRequired() async {
        let stub = SearchBackendStub()
        stub.loggedIn = false
        stub.results = [osResult(1)]
        let model = makeModel(stub)
        await model.search()
        #expect(model.phase == .loginRequired)
        // Statusen läses om innan den används, och ingen sökning görs utan konto.
        #expect(stub.refreshCalls == 1)
        #expect(stub.searchCalls == 0)

        // Sparade uppgifter som servern avvisar leder också till inloggning.
        let rejected = SearchBackendStub()
        rejected.results = [osResult(1)]
        rejected.downloadError = OpenSubtitlesError.invalidCredentials
        let other = makeModel(rejected)
        await other.search()
        await other.download(osResult(1))
        #expect(other.phase == .loginRequired)
    }

    @Test func rateLimitedDoesNotRetryAutomatically() async {
        let stub = SearchBackendStub()
        stub.searchError = OpenSubtitlesError.rateLimited(retryAfter: 1)
        let model = makeModel(stub)
        await model.search()
        #expect(model.phase == .failed(.rateLimited))
        for _ in 0..<10 { await Task.yield() }
        #expect(stub.searchCalls == 1)
        #expect(model.quota == nil)
    }

    @Test func errorsMapToFixedPhases() {
        typealias Model = SubtitleSearchModel
        #expect(Model.phase(for: SubtitleAccessError.notAllowed) == .failed(.notAllowed))
        #expect(Model.phase(for: SubtitleAccessError.featureDisabled) == .failed(.noKey))
        #expect(Model.phase(for: SubtitleAccessError.noQuery) == .empty)
        #expect(Model.phase(for: OpenSubtitlesError.noAPIKey) == .failed(.noKey))
        #expect(Model.phase(for: OpenSubtitlesError.notLoggedIn) == .loginRequired)
        #expect(Model.phase(for: OpenSubtitlesError.network) == .failed(.network))
        #expect(Model.phase(for: OpenSubtitlesError.badResponse) == .failed(.network))
        #expect(Model.phase(for: URLError(.notConnectedToInternet)) == .failed(.network))
        #expect(Model.phase(for: CancellationError()) == nil)
    }

    @Test func kidsAccessErrorShowsNotAllowedWithoutResults() async {
        let stub = SearchBackendStub()
        stub.searchError = SubtitleAccessError.notAllowed
        let model = makeModel(stub)
        await model.search()
        #expect(model.phase == .failed(.notAllowed))
    }

    @Test func cancelledSearchLeavesSearchingPhase() async {
        let stub = SearchBackendStub()
        stub.searchError = CancellationError()
        let model = makeModel(stub)
        await model.search()
        #expect(model.phase == .idle)
    }

    @Test func downloadReportsStoredSubtitleAndUpdatesQuota() async {
        let stub = SearchBackendStub()
        let found = osResult(11)
        stub.results = [found]
        var reported: [StoredSubtitle] = []
        let model = makeModel(stub, onDownloaded: { reported.append($0) })
        await model.search()
        await model.download(found)

        #expect(reported == [stub.stored])
        #expect(model.quota == OpenSubtitlesQuota(remaining: 8, allowed: 10))
        #expect(model.phase == .results([found]))
        #expect(stub.downloadCalls == 1)
    }

    @Test func failedDownloadCanGoBackToResults() async {
        let stub = SearchBackendStub()
        let found = osResult(11)
        stub.results = [found]
        stub.downloadError = OpenSubtitlesError.network
        let model = makeModel(stub)
        await model.search()
        await model.download(found)
        #expect(model.phase == .failed(.network))
        model.backToResults()
        #expect(model.phase == .results([found]))
    }

    @Test func downloadOnlyFromResultList() async {
        let stub = SearchBackendStub()
        let model = makeModel(stub)
        await model.download(osResult(1))
        #expect(stub.downloadCalls == 0)
        #expect(model.phase == .idle)
    }
}
