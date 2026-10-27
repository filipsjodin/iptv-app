import Testing
import Foundation
import Providers
import ProvidersTestSupport
@testable import Metadata

private let apiKey = "fakeomdbkey42"

private func omdb(_ response: StubResponse) -> StubHTTPClient {
    StubHTTPClient(responses: ["": response], key: { _ in "" })
}

@Test func omdbParsesRatings() async throws {
    let http = omdb(StubResponse(body: try metadataFixture("omdb_ratings.json")))
    let r = try await OMDbClient(apiKey: apiKey, http: http).ratings(imdbID: "tt15239678")
    #expect(r == ExternalRatings(imdb: 8.5, rottenTomatoes: 92))
    let url = try #require(http.lastURL)
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(url.host == "www.omdbapi.com" && url.scheme == "https")
    #expect(items.first { $0.name == "i" }?.value == "tt15239678")
    #expect(items.first { $0.name == "apikey" }?.value == apiKey)
}

@Test func omdbNotAvailableGivesNil() async throws {
    let http = omdb(StubResponse(body: try metadataFixture("omdb_na.json")))
    let r = try await OMDbClient(apiKey: apiKey, http: http).ratings(imdbID: "tt0000001")
    #expect(r == ExternalRatings(imdb: nil, rottenTomatoes: nil))
}

@Test func omdbErrorResponsesMap() async throws {
    let missing = omdb(StubResponse(body: try metadataFixture("omdb_error.json")))
    await #expect(throws: OMDbError.notFound) { try await OMDbClient(apiKey: apiKey, http: missing).ratings(imdbID: "tt0") }
    await #expect(throws: OMDbError.unauthorized) {
        try await OMDbClient(apiKey: apiKey, http: omdb(StubResponse(status: 401))).ratings(imdbID: "tt0")
    }
    await #expect(throws: OMDbError.http(500)) {
        try await OMDbClient(apiKey: apiKey, http: omdb(StubResponse(status: 500))).ratings(imdbID: "tt0")
    }
}

private struct LeakyFailingHTTP: HTTPClient {
    func get(_ url: URL) async throws -> (Data, Int) {
        throw URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url, NSURLErrorFailingURLStringErrorKey: url.absoluteString,
                                             NSLocalizedDescriptionKey: "timed out: \(url.absoluteString)"])
    }
}

@Test func omdbKeyRedactedInErrors() async {
    let client = OMDbClient(apiKey: apiKey, http: LeakyFailingHTTP())
    do {
        _ = try await client.ratings(imdbID: "tt15239678")
        Issue.record("should throw")
    } catch {
        let text = "\(error) \(String(reflecting: error)) \(error.localizedDescription)"
        #expect(!text.contains(apiKey))
        #expect(text.contains("REDACTED"))
        guard case .unavailable = error as? OMDbError else { Issue.record("expected unavailable, got \(error)"); return }
    }
    #expect(!String(describing: client).contains(apiKey))
    #expect(!String(reflecting: client).contains(apiKey))
}
