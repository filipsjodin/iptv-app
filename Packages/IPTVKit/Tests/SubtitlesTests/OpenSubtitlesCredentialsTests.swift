import Foundation
import Testing

@testable import Subtitles

private func result(_ id: Int, _ lang: String, rating: Double, downloads: Int) -> OpenSubtitlesResult {
    OpenSubtitlesResult(id: id, language: lang, release: "r\(id)", fileName: "f\(id)", rating: rating,
                        downloadCount: downloads, hearingImpaired: false, aiTranslated: false)
}

struct OpenSubtitlesCredentialsTests {
    @Test func credentialsNeverPrintSecrets() {
        let c = OpenSubtitlesCredentials(username: "anna-user", password: "hemligt-pw")
        for text in ["\(c)", String(reflecting: c), String(describing: c)] {
            #expect(!text.contains("anna-user") && !text.contains("hemligt-pw"))
        }
        var dumped = ""
        dump(c, to: &dumped)
        #expect(!dumped.contains("anna-user") && !dumped.contains("hemligt-pw"))
    }

    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemoryOpenSubtitlesCredentialStore()
        #expect(try store.load() == nil)
        try store.save(OpenSubtitlesCredentials(username: "u", password: "p"))
        #expect(try store.load() == OpenSubtitlesCredentials(username: "u", password: "p"))
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func sortsPreferredLanguagesThenRatingThenDownloads() {
        let all = [
            result(1, "en", rating: 9, downloads: 10),
            result(2, "sv", rating: 5, downloads: 10),
            result(3, "sv", rating: 8, downloads: 1),
            result(4, "sv", rating: 8, downloads: 50),
            result(5, "da", rating: 10, downloads: 99),
            result(6, "no", rating: 7, downloads: 5),
        ]
        let sorted = OpenSubtitlesResult.sorted(all, preferredLanguages: ["swe", "en"])
        #expect(sorted.map(\.id) == [4, 3, 2, 1, 5, 6])
    }
}
