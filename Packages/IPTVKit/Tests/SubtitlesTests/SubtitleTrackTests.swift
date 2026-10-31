import Testing
@testable import Subtitles

struct SubtitleTrackTests {
    let track = SubtitleTrack(cues: [
        SubtitleCue(start: 1, end: 3, text: "A"),
        SubtitleCue(start: 5, end: 7, text: "B"),
        SubtitleCue(start: 10, end: 12, text: "C"),
    ])

    @Test func cueAtFindsActiveCue() {
        #expect(track.cue(at: 1, offset: 0)?.text == "A")
        #expect(track.cue(at: 6, offset: 0)?.text == "B")
        #expect(track.cue(at: 11.9, offset: 0)?.text == "C")
    }

    @Test func cueAtRespectsPositiveAndNegativeOffset() {
        // Uppslagstid = tid + offset
        #expect(track.cue(at: 4, offset: 2)?.text == "B")
        #expect(track.cue(at: 7, offset: -2)?.text == "B")
        #expect(track.cue(at: 4, offset: 0) == nil)
    }

    @Test func cueAtOutsideAnyCueIsNil() {
        #expect(track.cue(at: 0.5, offset: 0) == nil)
        #expect(track.cue(at: 3, offset: 0) == nil)   // end är exklusivt
        #expect(track.cue(at: 4, offset: 0) == nil)
        #expect(track.cue(at: 99, offset: 0) == nil)
        #expect(SubtitleTrack(cues: []).cue(at: 1, offset: 0) == nil)
    }

    @Test func clampOffsetLimitsAndRoundsToTenths() {
        #expect(SubtitleTrack.clampOffset(1000) == 600)
        #expect(SubtitleTrack.clampOffset(-1000) == -600)
        #expect(SubtitleTrack.clampOffset(1.26) == 1.3)
        #expect(SubtitleTrack.clampOffset(-0.04) == 0)
        #expect(SubtitleTrack.clampOffset(0.5) == 0.5)
    }
}
