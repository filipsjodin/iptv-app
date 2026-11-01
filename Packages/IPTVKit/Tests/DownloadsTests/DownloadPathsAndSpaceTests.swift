import Foundation
import Testing
@testable import Downloads
import Core

@Suite struct DownloadPathsTests {
    @Test func pathsNeverContainTitleOrUnsafeCharacters() {
        let nasty = ["../../etc/passwd", "a/b", "..", ".", "", "Åäö 映画 🎬", String(repeating: "x", count: 5000),
                     "C:\\Windows\\x", "a\u{0}b", "name with spaces?*<>|:\""]
        var seen = Set<String>()
        for id in nasty {
            for kind in [ContentKind.movie, .series] {
                let dir = DownloadPaths.relativeDirectory(for: key(id, kind: kind))
                #expect(!dir.hasPrefix("/"))
                #expect(!dir.contains(".."))
                #expect(!dir.contains("\\"))
                #expect(dir.utf8.count <= 160)
                let parts = dir.split(separator: "/", omittingEmptySubsequences: false)
                #expect(parts.count == 4)
                #expect(parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
                #expect(dir.unicodeScalars.allSatisfy { s in
                    (s.value >= 48 && s.value <= 57) || (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122)
                        || s == "-" || s == "_" || s == "/" })
                #expect(seen.insert(dir).inserted, "kollision för \(id)")
            }
        }
        // Samma nyckel ger samma sökväg (deterministiskt).
        #expect(DownloadPaths.relativeDirectory(for: key("../x")) == DownloadPaths.relativeDirectory(for: key("../x")))
        // Olika spellistor ger olika kataloger.
        var other = key("1"); other.playlistID = UUID()
        #expect(DownloadPaths.relativeDirectory(for: other) != DownloadPaths.relativeDirectory(for: key("1")))
        // Id:n som liknar varandra efter sanering krockar inte.
        #expect(DownloadPaths.relativeDirectory(for: key("a/b")) != DownloadPaths.relativeDirectory(for: key("a_b")))
    }

    @Test func unknownContainerFallsBackToMp4OrBin() {
        #expect(DownloadPaths.fileName(container: "mkv") == "media.mkv")
        #expect(DownloadPaths.fileName(container: "MP4") == "media.mp4")
        #expect(DownloadPaths.fileName(container: nil) == "media.mp4")
        #expect(DownloadPaths.fileName(container: "") == "media.mp4")
        #expect(DownloadPaths.fileName(container: "../evil") == "media.bin")
        #expect(DownloadPaths.fileName(container: "exe") == "media.bin")
    }
}

@Suite struct DownloadSpaceTests {
    @Test func rejectsWhenNotEnoughWithReserve() {
        #expect(DownloadSpace.canStart(expectedBytes: 900, freeBytes: 1_000, reserveBytes: 100))
        #expect(!DownloadSpace.canStart(expectedBytes: 901, freeBytes: 1_000, reserveBytes: 100))
        #expect(!DownloadSpace.canStart(expectedBytes: 1, freeBytes: 50, reserveBytes: 100))
        #expect(DownloadSpace.canStart(expectedBytes: Int64.max, freeBytes: Int64.max, reserveBytes: 0))
        #expect(!DownloadSpace.canStart(expectedBytes: Int64.max, freeBytes: 10, reserveBytes: Int64.max))
    }

    @Test func unknownSizeAllowedWithReserveCheck() {
        #expect(DownloadSpace.canStart(expectedBytes: nil, freeBytes: 101, reserveBytes: 100))
        #expect(DownloadSpace.canStart(expectedBytes: nil, freeBytes: 100, reserveBytes: 100))
        #expect(!DownloadSpace.canStart(expectedBytes: nil, freeBytes: 99, reserveBytes: 100))
        #expect(!DownloadSpace.canStart(expectedBytes: nil, freeBytes: -5, reserveBytes: 0))
    }
}
