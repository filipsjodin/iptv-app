import Testing
@testable import Downloads

struct DownloadResponseCheckTests {
    @Test func okVideoPasses() {
        #expect(DownloadResponseCheck.failure(status: 200, contentType: "video/mp4") == nil)
        #expect(DownloadResponseCheck.failure(status: 206, contentType: nil) == nil)
        #expect(DownloadResponseCheck.failure(status: 200, contentType: "application/octet-stream") == nil)
    }

    @Test func unauthorizedAndForbiddenAreExpired() {
        #expect(DownloadResponseCheck.failure(status: 401, contentType: nil) == .expired)
        #expect(DownloadResponseCheck.failure(status: 403, contentType: "text/html") == .expired)
    }

    @Test func otherNon2xxIsBadStatus() {
        for status in [0, 199, 301, 404, 429, 500, 503] {
            #expect(DownloadResponseCheck.failure(status: status, contentType: "video/mp4") == .badStatus)
        }
    }

    @Test func htmlIsBadContent() {
        #expect(DownloadResponseCheck.failure(status: 200, contentType: "text/html") == .badContent)
        #expect(DownloadResponseCheck.failure(status: 200, contentType: "Text/HTML; charset=utf-8") == .badContent)
        #expect(DownloadResponseCheck.failure(status: 200, contentType: " application/xhtml+xml") == .badContent)
    }

    @Test func minimumBytes() {
        #expect(DownloadResponseCheck.minimumBytes(expectedBytes: nil) == DownloadResponseCheck.minimumPlausibleBytes)
        #expect(DownloadResponseCheck.minimumBytes(expectedBytes: 0) == DownloadResponseCheck.minimumPlausibleBytes)
        #expect(DownloadResponseCheck.minimumBytes(expectedBytes: 4_000_000_000) == DownloadResponseCheck.minimumPlausibleBytes)
        #expect(DownloadResponseCheck.minimumBytes(expectedBytes: 100) == 50)
        #expect(DownloadResponseCheck.minimumBytes(expectedBytes: 1) == 1)
    }
}
