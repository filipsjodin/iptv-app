import Testing
@testable import Core

@Test func parsesBadgesFromTitle() {
    #expect(QualityBadges.parse(title: "Film 2160p HDR10 Atmos 5.1", containerExtension: nil)
            == [.uhd4K, .hdr, .atmos, .surround51])
    #expect(QualityBadges.parse(title: "Plain", containerExtension: nil).isEmpty)
    #expect(QualityBadges.parse(title: "DoVi 4K", containerExtension: nil) == [.uhd4K, .dolbyVision])
    #expect(QualityBadges.parse(title: "Film UHD", containerExtension: nil) == [.uhd4K])
    #expect(QualityBadges.parse(title: "Film Dolby Vision", containerExtension: nil) == [.dolbyVision])
    #expect(QualityBadges.parse(title: "Film.2160p.DV.HDR10+.Atmos", containerExtension: "mkv")
            == [.uhd4K, .dolbyVision, .hdr, .atmos])
    #expect(QualityBadges.parse(title: "Film [5.1]", containerExtension: nil) == [.surround51])
}

@Test func parseIsCaseInsensitiveAndDeduplicated() {
    #expect(QualityBadges.parse(title: "film 4k uhd 2160P hdr HDR10 dolby VISION dovi DV atmos ATMOS 5.1 5.1",
                                containerExtension: nil) == QualityBadge.allCases)
    // Ordningen följer enumen, inte titeln.
    #expect(QualityBadges.parse(title: "5.1 Atmos HDR DV 4K", containerExtension: nil) == QualityBadge.allCases)
}

@Test func parseMatchesWholeWordsOnly() {
    #expect(QualityBadges.parse(title: "Film DVD", containerExtension: nil).isEmpty)
    #expect(QualityBadges.parse(title: "Film HDRip", containerExtension: nil).isEmpty)
    #expect(QualityBadges.parse(title: "Advanced Atmosphere", containerExtension: nil).isEmpty)
    #expect(QualityBadges.parse(title: "Sub4K 4Kids", containerExtension: nil).isEmpty)
    #expect(QualityBadges.parse(title: "Dolby Visionary", containerExtension: nil).isEmpty)
    #expect(QualityBadges.parse(title: "Dolby", containerExtension: nil).isEmpty)
    #expect(QualityBadges.parse(title: "Room 15.1 and 5.10 and 5.1.2", containerExtension: nil).isEmpty)
    #expect(QualityBadges.parse(title: "Film DV", containerExtension: nil) == [.dolbyVision])
}

@Test func containerExtensionDoesNotChangeBadges() {
    let title = "Film 4K"
    #expect(QualityBadges.parse(title: title, containerExtension: "mkv")
            == QualityBadges.parse(title: title, containerExtension: nil))
}
