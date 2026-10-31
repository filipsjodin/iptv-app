import Testing
import Foundation
import Core
import ProvidersTestSupport
@testable import Providers

private func shortEPGClient(_ json: String, status: Int = 200) -> XtreamClient {
    let http = StubHTTPClient(responses: ["get_short_epg": StubResponse(body: Data(json.utf8), status: status)])
    return XtreamClient(server: URL(string: "http://example.invalid")!, username: "REDACTED", password: "REDACTED", http: http)
}

private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

@Test func shortEPGDecodesBase64TitleAndSummary() async throws {
    let json = """
    {"epg_listings":[
      {"id":"1","title":"\(b64("Nyheter åäö"))","description":"\(b64("Dagens nyheter"))",
       "start":"2023-11-14 22:13:20","end":"2023-11-14 23:13:20","start_timestamp":"1700000000","stop_timestamp":"1700003600"},
      {"id":"2","title":"\(b64("Väder"))","description":"",
       "start":"2023-11-14 23:13:20","end":"2023-11-14 23:20:00","start_timestamp":"","stop_timestamp":""},
      {"id":"3","title":"\(b64("Trasig"))","start_timestamp":"1700003600","stop_timestamp":"1700000000"},
      {"id":"4","title":"","start_timestamp":"1700000000","stop_timestamp":"1700003600"}
    ]}
    """
    let list = try await shortEPGClient(json).shortEPG(streamID: "42", limit: 2)
    #expect(list.count == 2)
    #expect(list[0].title == "Nyheter åäö")
    #expect(list[0].summary == "Dagens nyheter")
    #expect(list[0].channelID == "42")
    #expect(list[0].start == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(list[0].end == Date(timeIntervalSince1970: 1_700_003_600))
    // Tider som text tolkas som UTC när unix-sekunder saknas.
    #expect(list[1].start == Date(timeIntervalSince1970: 1_700_003_600))
    #expect(list[1].summary == nil)
}

@Test func shortEPGSendsStreamIDAndLimit() async throws {
    let http = StubHTTPClient(responses: ["get_short_epg": StubResponse(body: Data("{\"epg_listings\":[]}".utf8))])
    let c = XtreamClient(server: URL(string: "http://example.invalid")!, username: "u", password: "p", http: http)
    let list = try await c.shortEPG(streamID: "7", limit: 3)
    #expect(list.isEmpty)
    let q = URLComponents(url: try #require(http.lastURL), resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(q.first { $0.name == "stream_id" }?.value == "7")
    #expect(q.first { $0.name == "limit" }?.value == "3")
}

@Test func shortEPGHandlesEmptyAndBrokenResponses() async throws {
    #expect(try await shortEPGClient("").shortEPG(streamID: "1", limit: 2).isEmpty)
    #expect(try await shortEPGClient("{\"epg_listings\":[]}").shortEPG(streamID: "1", limit: 2).isEmpty)
    await #expect(throws: ProviderError.invalidResponse) { try await shortEPGClient("<html>").shortEPG(streamID: "1", limit: 2) }
    await #expect(throws: ProviderError.unauthorized) { try await shortEPGClient("", status: 401).shortEPG(streamID: "1", limit: 2) }
}
