import Testing
import Foundation
import Core
import ProvidersTestSupport
@testable import Providers

private func client(fixtures: [String: String]) -> XtreamClient { xtreamClient(fixtures: fixtures) }

@Test func accountParsesStringNumbersAndExpiry() async throws {
    let a = try await client(fixtures: ["": "xtream_user_info.json"]).account()
    #expect(a.maxConnections == 2)
    #expect(a.expiresAt == Date(timeIntervalSince1970: 1_798_761_600))
    #expect(a.allowedOutputFormats == ["m3u8", "ts"])
}
@Test func authZeroIsUnauthorized() async {
    await #expect(throws: ProviderError.unauthorized) { try await client(fixtures: ["": "xtream_auth0.json"]).account() }
}
@Test func expiredAccountIsReported() async {
    await #expect(throws: ProviderError.accountExpired(Date(timeIntervalSince1970: 1_600_000_000))) {
        try await client(fixtures: ["": "xtream_expired.json"]).account()
    }
}
@Test func catalogSurvivesSloppyRows() async throws {
    let c = try await client(fixtures: standardFixtures).catalog()
    #expect(c.movies.count == 5)
    #expect(c.movies.first { $0.providerID == "101" }?.container == "mkv")
    #expect(c.movies.first { $0.providerID == "102" }?.container == "mp4")
    #expect(c.movies.first { $0.providerID == "101" }?.locator == .xtream(kind: .movie, streamID: "101", container: "mkv"))
    #expect(c.movies.first { $0.providerID == "101" }?.addedAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(c.movies.first { $0.providerID == "102" }?.rating == nil)
    #expect(c.movies.first { $0.providerID == "102" }?.posterURL == nil)
    #expect(c.live.count == 2)
    #expect(c.live.allSatisfy { if case .xtream(.live, _, "m3u8") = $0.locator { true } else { false } })
    #expect(c.series.count == 2)
    #expect(c.categories.count == 2 + 1 + 2)
}
@Test func liveUsesTsWhenM3u8NotAllowed() async throws {
    var f = standardFixtures
    f[""] = "xtream_user_info_ts.json"
    let c = try await client(fixtures: f).catalog()
    #expect(c.live.allSatisfy { if case .xtream(.live, _, "ts") = $0.locator { true } else { false } })
}
@Test func catalogToleratesEmptyLists() async throws {
    var f = standardFixtures
    f["get_vod_streams"] = "xtream_empty_object.json"
    f["get_series"] = "xtream_empty_list.json"
    f["get_live_streams"] = "xtream_empty_object.json"
    f["get_live_categories"] = "xtream_empty_list.json"
    let c = try await client(fixtures: f).catalog()
    #expect(c.movies.isEmpty && c.series.isEmpty && c.live.isEmpty)
}
@Test func catalogFailsOnAuthError() async {
    await #expect(throws: ProviderError.unauthorized) {
        try await client(fixtures: ["": "xtream_auth0.json"]).catalog()
    }
}
@Test func seriesInfoAcceptsArrayOrObjectEpisodes() async throws {
    let objectForm = try await client(fixtures: ["get_series_info": "xtream_series_info_object.json"]).episodes(seriesID: "5")
    let arrayForm = try await client(fixtures: ["get_series_info": "xtream_series_info_array.json"]).episodes(seriesID: "5")
    #expect(objectForm.count == 3 && arrayForm.count == 3)
    #expect(objectForm.map(\.season) == [1, 1, 2])
    #expect(arrayForm.map(\.season) == [1, 1, 2])
    #expect(objectForm == arrayForm)
    #expect(objectForm[0].providerID == "501")
    #expect(objectForm[0].locator == .xtream(kind: .series, streamID: "501", container: "mkv"))
    #expect(objectForm[1].locator == .xtream(kind: .series, streamID: "502", container: "mp4"))
}
@Test func unreachableMapsToProviderError() async {
    await #expect(throws: ProviderError.unreachable) {
        try await XtreamClient(server: URL(string: "http://h")!, username: "u", password: "p", http: FailingHTTPClient(URLError(.timedOut))).account()
    }
}

private struct StatusHTTPClient: HTTPClient {
    let status: Int
    func get(_ url: URL) async throws -> (Data, Int) { (Data("x".utf8), status) }
}

@Test func httpStatusesMapToProviderErrors() async {
    func make(_ s: Int) -> XtreamClient {
        XtreamClient(server: URL(string: "http://h")!, username: "u", password: "p", http: StatusHTTPClient(status: s))
    }
    await #expect(throws: ProviderError.unauthorized) { try await make(401).account() }
    await #expect(throws: ProviderError.unauthorized) { try await make(403).account() }
    await #expect(throws: ProviderError.http(503)) { try await make(503).account() }
    await #expect(throws: ProviderError.invalidResponse) { try await make(200).account() }
}

@Test func disabledAccountIsReported() async {
    await #expect(throws: ProviderError.accountDisabled) {
        try await client(fixtures: ["": "xtream_disabled.json"]).account()
    }
}

@Test func requestUrlEncodesCredentialsAndNothingLeaks() async throws {
    final class Box: @unchecked Sendable { var url: URL? }
    struct Capture: HTTPClient {
        let box: Box
        func get(_ url: URL) async throws -> (Data, Int) { box.url = url; throw URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: url]) }
    }
    let box = Box()
    let c = XtreamClient(server: URL(string: "http://example.invalid:8080/")!, username: "us er", password: "p&w+1", http: Capture(box: box))
    do { _ = try await c.account(); Issue.record("should throw") } catch {
        #expect(error as? ProviderError == .unreachable)
        let text = "\(error) \(c) \(String(reflecting: c))"
        #expect(!text.contains("example.invalid") && !text.contains("p&w") && !text.contains("us er"))
    }
    let s = try #require(box.url?.absoluteString)
    #expect(s == "http://example.invalid:8080/player_api.php?username=us%20er&password=p%26w%2B1")
    var dumped = ""
    dump(c, to: &dumped)
    #expect(!dumped.contains("p&w"))
}

@Test func providerErrorDescriptionsContainNoUrls() {
    let all: [ProviderError] = [.unauthorized, .accountExpired(Date()), .accountDisabled, .unreachable, .http(500), .invalidResponse]
    for e in all { #expect(!e.description.contains("http") && !e.description.contains("://")) }
}

@Test func lenientDecodingRules() throws {
    struct T: Decodable {
        @LenientInt var a: Int?
        @LenientInt var b: Int?
        @LenientInt var c: Int?
        @LenientDouble var d: Double?
        @LenientDouble var e: Double?
        @LenientString var f: String?
        @LenientString var g: String?
        @LenientInt var missing: Int?
        enum CodingKeys: String, CodingKey { case a, b, c, d, e, f, g, missing }
        init(from decoder: Decoder) throws {
            let k = try decoder.container(keyedBy: CodingKeys.self)
            _a = try k.decode(LenientInt.self, forKey: .a); _b = try k.decode(LenientInt.self, forKey: .b)
            _c = try k.decode(LenientInt.self, forKey: .c); _d = try k.decode(LenientDouble.self, forKey: .d)
            _e = try k.decode(LenientDouble.self, forKey: .e); _f = try k.decode(LenientString.self, forKey: .f)
            _g = try k.decode(LenientString.self, forKey: .g); _missing = try k.decode(LenientInt.self, forKey: .missing)
        }
    }
    let json = #"{"a":"7","b":"","c":null,"d":"7.5","e":[1],"f":12,"g":""}"#
    let t = try JSONDecoder().decode(T.self, from: Data(json.utf8))
    #expect(t.a == 7 && t.b == nil && t.c == nil && t.d == 7.5 && t.e == nil && t.f == "12" && t.g == nil && t.missing == nil)
}

private struct ListStub: HTTPClient {
    let listStatus: Int
    let listBody: String
    func get(_ url: URL) async throws -> (Data, Int) {
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
        if action == nil { return (try XtreamFixtures.data(named: "xtream_user_info.json"), 200) }
        return (Data(listBody.utf8), listStatus)
    }
}

@Test func emptyBodiesGiveEmptyCatalogButServerErrorsFail() async throws {
    let base = URL(string: "http://h")!
    let c = try await XtreamClient(server: base, username: "u", password: "p", http: ListStub(listStatus: 200, listBody: "")).catalog()
    #expect(c.movies.isEmpty && c.live.isEmpty && c.categories.isEmpty)
    await #expect(throws: ProviderError.http(500)) {
        try await XtreamClient(server: base, username: "u", password: "p", http: ListStub(listStatus: 500, listBody: "")).catalog()
    }
}

private struct BodyStub: HTTPClient {
    var account = "xtream_user_info.json"
    var accountBody: String?
    var listBodies: [String: String] = [:]
    var statuses: [String: Int] = [:]
    func get(_ url: URL) async throws -> (Data, Int) {
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
        guard let action else {
            if let accountBody { return (Data(accountBody.utf8), 200) }
            return (try XtreamFixtures.data(named: account), 200)
        }
        if let s = statuses[action], s != 200 { return (Data(), s) }
        if let b = listBodies[action] { return (Data(b.utf8), 200) }
        return (Data("[]".utf8), 200)
    }
}
private func xc(_ stub: BodyStub) -> XtreamClient {
    XtreamClient(server: URL(string: "http://h")!, username: "u", password: "p", http: stub)
}

@Test func nonListBodiesAreInvalidResponseNotEmpty() async {
    for body in ["<html><body>Login</body></html>", #"[{"stream_id":1,"name":"x"}"#, #"{"error":"nope"}"#, #"{"error":{"code":1}}"#, "false", "42"] {
        await #expect(throws: ProviderError.invalidResponse, "body: \(body)") {
            try await xc(BodyStub(listBodies: ["get_vod_streams": body])).catalog()
        }
    }
}
@Test func objectKeyedListsAreDecodedInKeyOrder() async throws {
    let body = #"{"10":{"stream_id":3,"name":"C"},"2":{"stream_id":2,"name":"B"},"1":{"stream_id":1,"name":"A"}}"#
    let c = try await xc(BodyStub(listBodies: ["get_vod_streams": body])).catalog()
    #expect(c.movies.map(\.providerID) == ["1", "2", "3"])
}
@Test func http404OnStreamListFailsButCategoryListIsEmpty() async throws {
    await #expect(throws: ProviderError.http(404)) {
        try await xc(BodyStub(statuses: ["get_vod_streams": 404])).catalog()
    }
    let c = try await xc(BodyStub(statuses: ["get_vod_categories": 404])).catalog()
    #expect(c.categories.isEmpty)
}
@Test func blankAndNullBodiesAreEmpty() async throws {
    let c = try await xc(BodyStub(listBodies: ["get_vod_streams": "  \n", "get_series": "null", "get_live_streams": "{}"])).catalog()
    #expect(c.movies.isEmpty && c.series.isEmpty && c.live.isEmpty)
}
@Test func boolAuthAndTrialAreHandled() async throws {
    await #expect(throws: ProviderError.unauthorized) { try await xc(BodyStub(accountBody: #"{"user_info":{"auth":false,"status":"Active"}}"#)).account() }
    await #expect(throws: ProviderError.unauthorized) { try await xc(BodyStub(accountBody: #"{"user_info":{"auth":"0"}}"#)).account() }
    await #expect(throws: ProviderError.unauthorized) { try await xc(BodyStub(accountBody: #"{"user_info":{"auth":"false"}}"#)).account() }
    await #expect(throws: ProviderError.unauthorized) { try await xc(BodyStub(accountBody: #"{"user_info":{"status":"Inactive"}}"#)).account() }
    let a = try await xc(BodyStub(accountBody: #"{"user_info":{"auth":true,"status":"Active","is_trial":true}}"#)).account()
    #expect(a.isTrial)
    let b = try await xc(BodyStub(accountBody: #"{"user_info":{"status":"Active"}}"#)).account()
    #expect(b.status == "Active")
}
@Test func duplicatesKeepFirstOccurrence() async throws {
    let vod = #"[{"stream_id":1,"name":"First"},{"stream_id":"1","name":"Second"}]"#
    let cats = #"[{"category_id":"1","category_name":"A"},{"category_id":1,"category_name":"B"}]"#
    let c = try await xc(BodyStub(listBodies: ["get_vod_streams": vod, "get_vod_categories": cats])).catalog()
    #expect(c.movies.map(\.title) == ["First"])
    #expect(c.categories.map(\.name) == ["A"])
}
@Test func episodesWithWrongShapeAreInvalidResponse() async {
    await #expect(throws: ProviderError.invalidResponse) {
        try await xc(BodyStub(listBodies: ["get_series_info": #"{"episodes":"oops"}"#])).episodes(seriesID: "5")
    }
}
@Test func episodesGetEnglishDefaultTitleAndStableOrder() async throws {
    let body = #"{"episodes":{"1":[{"id":"b","episode_num":1},{"id":"a","episode_num":1}]}}"#
    let eps = try await xc(BodyStub(listBodies: ["get_series_info": body])).episodes(seriesID: "5")
    #expect(eps.map(\.providerID) == ["a", "b"])
    #expect(eps[0].title == "Episode 1")
}
@Test func resourceTimeoutIsConfigurable() {
    _ = URLSessionHTTPClient()
    _ = URLSessionHTTPClient(timeout: 10, resourceTimeout: 100)
}

@Test func catalogWithPrefetchedAccountSkipsAuth() async throws {
    let stub = StubHTTPClient(fixtures: standardFixtures)
    let c = XtreamClient(server: URL(string: "http://h.example")!, username: "u", password: "p", http: stub)
    let acc = try await c.account()
    let before = stub.requestCount(action: "")
    #expect(before == 1)
    _ = try await c.catalog(account: acc)
    #expect(stub.requestCount(action: "") == before)
}

@Test func xtreamCatalogMarksEpisodesIncomplete() async throws {
    #expect(try await xtreamClient(fixtures: standardFixtures).catalog().episodesComplete == false)
}

@Test func decodeRowsHandlesBlankNullAndEmptyWithWhitespace() throws {
    for body in ["", "  \n", "null", " null\n", "[]", " [ ] ", "{}", "\n{ \t}\n"] {
        let rows: [XtreamVodDTO] = try XtreamClient.decodeRows(Data(body.utf8))
        #expect(rows.isEmpty)
    }
}
