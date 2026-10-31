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

/// Ett stubbat svar: body, status och svarsheaders (t.ex. `Retry-After`).
public struct StubResponse: Sendable {
    public var body: Data
    public var status: Int
    public var headers: [String: String]
    public init(body: Data = Data(), status: Int = 200, headers: [String: String] = [:]) {
        self.body = body
        self.status = status
        self.headers = headers
    }
    /// Läser en fixtur ur ProvidersTestSupport-bundlen.
    public static func fixture(_ name: String, status: Int = 200, headers: [String: String] = [:]) throws -> StubResponse {
        StubResponse(body: try XtreamFixtures.data(named: name), status: status, headers: headers)
    }
}

/// Mappar en nyckel ur URL:en (som standard `action` i queryn, tom sträng när den saknas) till ett svar.
/// Okänd nyckel ger HTTP 404. Fångar senaste URL och request-headers (trådsäkert).
public struct StubHTTPClient: HTTPClient {
    public let fixtures: [String: String]
    private let responses: [String: StubResponse]
    private let key: @Sendable (URL) -> String
    private let counter = RequestCounter()

    public init(fixtures: [String: String]) {
        self.fixtures = fixtures
        self.responses = [:]
        self.key = StubHTTPClient.actionKey
    }

    /// Färdiga svar per nyckel; `key` räknar ut nyckeln ur URL:en (standard: `action`-parametern).
    public init(responses: [String: StubResponse], key: @escaping @Sendable (URL) -> String = StubHTTPClient.actionKey) {
        self.fixtures = [:]
        self.responses = responses
        self.key = key
    }

    @Sendable public static func actionKey(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == "action" }?.value ?? ""
    }

    /// Antal gjorda anrop med given nyckel (`action`; "" = anrop utan `action`). Trådsäker.
    public func requestCount(action: String) -> Int { counter.count(action) }
    /// Senaste anropets URL respektive request-headers.
    public var lastURL: URL? { counter.last?.url }
    public var lastHeaders: [String: String]? { counter.last?.headers }
    /// Alla gjorda anrop i ordning.
    public var requests: [(url: URL, headers: [String: String])] { counter.all }

    public func get(_ url: URL) async throws -> (Data, Int) {
        let (data, status, _) = try await get(url, headers: [:])
        return (data, status)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int, [String: String]) {
        let k = key(url)
        counter.record(k, url: url, headers: headers)
        if let r = responses[k] { return (r.body, r.status, r.headers) }
        guard let file = fixtures[k] else { return (Data(), 404, [:]) }
        return (try XtreamFixtures.data(named: file), 200, [:])
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var log: [(url: URL, headers: [String: String])] = []
    func record(_ action: String, url: URL, headers: [String: String]) {
        lock.lock(); counts[action, default: 0] += 1; log.append((url, headers)); lock.unlock()
    }
    func count(_ action: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[action, default: 0] }
    var last: (url: URL, headers: [String: String])? { lock.lock(); defer { lock.unlock() }; return log.last }
    var all: [(url: URL, headers: [String: String])] { lock.lock(); defer { lock.unlock() }; return log }
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

/// Testhjälpare för XMLTV-fixturer.
public enum XMLTVFixtures {
    public static func url(named name: String = "xmltv-sample") throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures") else {
            throw URLError(.fileDoesNotExist)
        }
        return url
    }
}
