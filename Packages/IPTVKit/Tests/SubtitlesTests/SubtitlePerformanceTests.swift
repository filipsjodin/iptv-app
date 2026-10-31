import Foundation
import Testing
@testable import Subtitles

struct SubtitlePerformanceTests {
    private static func makeSRT(cues: Int) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int(t * 1000)
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var out = ""
        out.reserveCapacity(cues * 80)
        for i in 0..<cues {
            let start = Double(i) * 2.5
            out += "\(i + 1)\n\(stamp(start)) --> \(stamp(start + 2))\nRad ett åäö \(i)\nRad två\n\n"
        }
        return out
    }

    private static func ms(_ block: () -> Void) -> Double {
        let clock = ContinuousClock()
        let d = clock.measure(block)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    @Test func parse5000CuesIsFast() {
        let srt = Self.makeSRT(cues: 5000)
        var count = 0
        let t = Self.ms { count = SubtitleParser.parse(srt).count }
        print("PERF subtitle-parse \(String(format: "%.1f", t)) ms")
        #expect(count == 5000)
        #expect(t < 2000)  // generöst CI-tak
    }

    @Test func lookupIsNotLinear() {
        func lookupMs(cueCount: Int) -> Double {
            let track = SubtitleTrack(cues: SubtitleParser.parse(Self.makeSRT(cues: cueCount)))
            let span = Double(cueCount) * 2.5
            return Self.ms {
                var hits = 0
                for i in 0..<100_000 {
                    let time = span * Double(i % 1000) / 1000
                    if track.cue(at: time, offset: 0.1) != nil { hits += 1 }
                }
                #expect(hits > 0)
            }
        }
        let small = lookupMs(cueCount: 500)
        let large = lookupMs(cueCount: 5000)
        print("PERF subtitle-lookup \(String(format: "%.1f", large)) ms (100000 uppslag, 5000 cues; 500 cues \(String(format: "%.1f", small)) ms)")
        #expect(large < 2000)
        // 10x fler cues ska inte ge nära 10x tid (linjärt); generös marginal för brus.
        #expect(large < max(small, 5) * 5)
    }
}
