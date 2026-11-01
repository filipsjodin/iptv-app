import Foundation
import Testing
@testable import Downloads
import Core

@Suite struct DownloadSnapshotCodableTests {
    @Test func roundTripsAndKeepsLocatorWithoutCredentials() throws {
        let snapshot = DownloadSnapshot(
            title: "Film", year: 2001, season: 1, episode: 2, container: "mkv", durationSeconds: 60,
            seriesProviderID: "s1", seriesTitle: "Serie",
            locator: .xtream(kind: .movie, streamID: "42", container: "mkv"), expectedBytes: 1000,
            addedAt: Date(timeIntervalSince1970: 1234))
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(DownloadSnapshot.self, from: data) == snapshot)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("http"))
        #expect(!text.contains("password"))
    }
}
