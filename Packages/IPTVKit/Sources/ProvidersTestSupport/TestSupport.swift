import Foundation
import Providers
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Testhjälpare för Xtream-baserade tester (delas av IPTVKit-, plattforms- och apptester).
public enum XtreamFixtures {
    public static func data(named name: String) throws -> Data {
        let base = (name as NSString).deletingPathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: "json", subdirectory: "Fixtures") else {
            throw URLError(.fileDoesNotExist)
        }
        return try Data(contentsOf: url)
    }
}

/// Mappar `action` i URL-queryn (tom sträng när den saknas) till en fixture-fil. Okänd action ger HTTP 404.
public struct StubHTTPClient: HTTPClient {
    public let fixtures: [String: String]
    private let counter = RequestCounter()

    public init(fixtures: [String: String]) { self.fixtures = fixtures }

    /// Antal gjorda anrop med given `action` ("" = anrop utan `action`). Trådsäker.
    public func requestCount(action: String) -> Int { counter.count(action) }

    public func get(_ url: URL) async throws -> (Data, Int) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let action = items.first { $0.name == "action" }?.value ?? ""
        counter.record(action)
        guard let file = fixtures[action] else { return (Data(), 404) }
        return (try XtreamFixtures.data(named: file), 200)
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func record(_ action: String) { lock.lock(); counts[action, default: 0] += 1; lock.unlock() }
    func count(_ action: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[action, default: 0] }
}

public struct FailingHTTPClient: HTTPClient {
    public let error: URLError
    public init(_ error: URLError) { self.error = error }
    public func get(_ url: URL) async throws -> (Data, Int) { throw error }
}

public let standardFixtures: [String: String] = [
    "": "xtream_user_info.json",
    "get_vod_categories": "xtream_vod_categories.json",
    "get_series_categories": "xtream_series_categories.json",
    "get_live_categories": "xtream_live_categories.json",
    "get_vod_streams": "xtream_vod_streams.json",
    "get_series": "xtream_series.json",
    "get_live_streams": "xtream_live_streams.json",
    "get_series_info": "xtream_series_info_object.json",
]

public func xtreamClient(fixtures: [String: String]) -> XtreamClient {
    XtreamClient(server: URL(string: "http://example.invalid")!, username: "REDACTED", password: "REDACTED",
                 http: StubHTTPClient(fixtures: fixtures))
}
