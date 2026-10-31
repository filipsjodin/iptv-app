import Testing
@testable import PlaybackCore

@Test func handheldNeverAutoStarts() {
    #expect(!PreviewPolicy.autoStartsOnAppear(.handheld))
}

@Test func tvAutoStarts() {
    #expect(PreviewPolicy.autoStartsOnAppear(.tv))
}

@Test func userStartedPreviewRequiresSettingAndNotKids() {
    for platform in [PreviewPlatform.tv, .handheld] {
        #expect(PreviewPolicy.allowsUserStartedPreview(platform, previewsEnabled: true, kids: false))
        #expect(!PreviewPolicy.allowsUserStartedPreview(platform, previewsEnabled: false, kids: false))
        #expect(!PreviewPolicy.allowsUserStartedPreview(platform, previewsEnabled: true, kids: true))
        #expect(!PreviewPolicy.allowsUserStartedPreview(platform, previewsEnabled: false, kids: true))
    }
}
