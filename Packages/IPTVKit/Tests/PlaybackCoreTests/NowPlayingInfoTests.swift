import Testing
@testable import PlaybackCore

@Test func pausedHasRateZero() {
    let info = NowPlayingInfo(title: "T", elapsed: 10, duration: 100, isPlaying: false, isLive: false)
    #expect(info.playbackRate == 0)
    let playing = NowPlayingInfo(title: "T", elapsed: 10, duration: 100, isPlaying: true, isLive: false)
    #expect(playing.playbackRate == 1)
}

@Test func liveHasNoDuration() {
    let info = NowPlayingInfo(title: "T", elapsed: 10, duration: 100, isPlaying: true, isLive: true)
    #expect(info.durationForDisplay == nil)
}

@Test func elapsedIsClampedToDuration() {
    let info = NowPlayingInfo(title: "T", elapsed: 150, duration: 100, isPlaying: true, isLive: false)
    #expect(info.elapsedClamped == 100)
    let unknown = NowPlayingInfo(title: "T", elapsed: 150, duration: nil, isPlaying: true, isLive: false)
    #expect(unknown.elapsedClamped == 150)
}

@Test func negativeElapsedIsZero() {
    let info = NowPlayingInfo(title: "T", elapsed: -5, duration: 100, isPlaying: true, isLive: false)
    #expect(info.elapsedClamped == 0)
    let nan = NowPlayingInfo(title: "T", elapsed: .nan, duration: 100, isPlaying: true, isLive: false)
    #expect(nan.elapsedClamped == 0)
}

@Test func nonPositiveDurationIsNil() {
    for d in [0.0, -1, .nan, .infinity] {
        let info = NowPlayingInfo(title: "T", elapsed: 1, duration: d, isPlaying: true, isLive: false)
        #expect(info.durationForDisplay == nil)
    }
}
