import AVFoundation
#if os(tvOS)
import AVKit
#endif
import Foundation
import Testing
import Playback
import PlaybackCore
import PlaybackTestSupport

@MainActor @Suite(.serialized) struct AVPlayerEngineTests {
    @Test func playsGeneratedMovieAndReportsDuration() async throws {
        let url = try await TestMedia.makeMovie(seconds: 2)
        let e = AVPlayerEngine()
        #expect(e.kind == .avPlayer)
        try await e.load(url: url, startAt: nil)
        #expect(abs((e.duration ?? 0) - 2) < 0.2)
        #expect(e.videoInfo.dynamicRange == .sdr)
        #expect(e.videoInfo.height != nil)
        e.close()
        #expect(e.state == .idle)
    }

    @Test func externalMetadataHasTitleOnly() async throws {
        let url = try await TestMedia.makeMovie(seconds: 2)
        let items = AVPlayerEngine.externalMetadata(title: "Min film")
        #expect(items.count == 1)
        #expect(items.first?.identifier == .commonIdentifierTitle)
        let value = try await items.first?.load(.stringValue)
        #expect(value == "Min film")
        #expect(AVPlayerEngine.externalMetadata(title: nil).isEmpty)

        // Laddning med titel fungerar på alla plattformar; på tvOS hamnar titeln i externalMetadata.
        let e = AVPlayerEngine(title: "Min film")
        try await e.load(url: url, startAt: nil)
        #if os(tvOS)
        #expect(e.player.currentItem?.externalMetadata.count == 1)
        #endif
        e.close()
        #expect(e.player.currentItem == nil)
    }

    @Test func closeAndWaitReleasesItem() async throws {
        let url = try await TestMedia.makeMovie(seconds: 2)
        let e = AVPlayerEngine()
        try await e.load(url: url, startAt: nil)
        await e.closeAndWait()
        #expect(e.state == .idle)
        #expect(e.player.currentItem == nil)
    }

    @Test func startAtSeeks() async throws {
        let url = try await TestMedia.makeMovie(seconds: 3)
        let e = AVPlayerEngine()
        try await e.load(url: url, startAt: 1.0)
        #expect(e.currentTime >= 0.9)
        e.close()
    }

    @Test func missingFileFailsFast() async {
        let start = ContinuousClock.now
        await #expect(throws: PlaybackFailure.self) {
            try await AVPlayerEngine().load(url: URL(fileURLWithPath: "/nonexistent.mp4"), startAt: nil)
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test(.timeLimit(.minutes(1))) func unreachableHostFailsAsNetworkOrTimeout() async {
        let start = ContinuousClock.now
        let e = AVPlayerEngine()
        do {
            try await e.load(url: URL(string: "http://203.0.113.7:9/x.m3u8")!, startAt: nil)
            Issue.record("expected a failure")
        } catch let f as PlaybackFailure {
            #expect(f == .network || f == .timeout)
            #expect(e.state == .failed(f))
        } catch {
            Issue.record("expected PlaybackFailure")
        }
        #expect(ContinuousClock.now - start < .seconds(20))
        e.close()
    }

    @Test func shortTimeoutFailsAsTimeout() async {
        let e = AVPlayerEngine(loadTimeout: .milliseconds(1))
        do {
            try await e.load(url: URL(string: "http://203.0.113.7:9/y.m3u8")!, startAt: nil)
            Issue.record("expected a failure")
        } catch let f as PlaybackFailure {
            #expect(f == .timeout || f == .network)
        } catch {
            Issue.record("expected PlaybackFailure")
        }
        e.close()
    }
}

@Suite struct ErrorMappingTests {
    @Test func urlErrorsAreNetwork() {
        let e = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(AVPlayerEngine.failure(for: e) == .network)
    }

    @Test func wrappedUrlErrorIsNetwork() {
        let inner = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        let outer = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: inner])
        #expect(AVPlayerEngine.failure(for: outer) == .network)
    }

    @Test func unsupportedFormatCodes() {
        for code in [-11828, -11833] {
            let e = NSError(domain: "AVFoundationErrorDomain", code: code)
            #expect(AVPlayerEngine.failure(for: e) == .unsupportedFormat)
        }
    }

    @Test func otherErrorsAreUnknown() {
        #expect(AVPlayerEngine.failure(for: NSError(domain: "AVFoundationErrorDomain", code: -11819)) == .unknown)
        #expect(AVPlayerEngine.failure(for: NSError(domain: "x", code: 1)) == .unknown)
        #expect(AVPlayerEngine.failure(for: nil) == .unknown)
    }
}

@Suite struct VideoInfoTests {
    @Test func summaryFormatting() {
        #expect(VideoInfo(width: 3840, height: 2160, dynamicRange: .dolbyVision, videoCodec: "hvc1", audioDescription: "Atmos", bitrate: 18_000_000, frameRate: 24).summary == "2160p · Dolby Vision · Atmos")
        #expect(VideoInfo(width: 1920, height: 1080, dynamicRange: .sdr, videoCodec: nil, audioDescription: nil, bitrate: nil, frameRate: nil).summary == "1080p")
        #expect(VideoInfo(width: nil, height: nil, dynamicRange: .hdr10, videoCodec: nil, audioDescription: "5.1", bitrate: nil, frameRate: nil).summary == "HDR10 · 5.1")
        #expect(VideoInfo(width: nil, height: 720, dynamicRange: .hlg, videoCodec: nil, audioDescription: nil, bitrate: nil, frameRate: nil).summary == "720p · HLG")
        #expect(VideoInfo.unknown.summary == "")
    }

    @Test func dynamicRangeClassification() {
        // Dolby Vision profil 8.x: hvc1 med dvcC-konfiguration och PQ- eller HLG-bas.
        #expect(DynamicRange.classify(codecs: ["hvc1"], transferFunction: "SMPTE_ST_2084_PQ", hasDolbyVisionConfig: true) == .dolbyVision)
        #expect(DynamicRange.classify(codecs: ["hvc1"], transferFunction: "ITU_R_2100_HLG", hasDolbyVisionConfig: true) == .dolbyVision)
        #expect(DynamicRange.classify(codecs: ["hvc1"], transferFunction: "SMPTE_ST_2084_PQ", hasDolbyVisionConfig: false) == .hdr10)
        #expect(DynamicRange.classify(codecs: ["hvc1"], transferFunction: "ITU_R_2100_HLG", hasDolbyVisionConfig: false) == .hlg)
        #expect(DynamicRange.classify(codecs: ["dvh1"], transferFunction: nil, hasDolbyVisionConfig: false) == .dolbyVision)
        #expect(DynamicRange.classify(codecs: ["hvc1", "dvh1"], transferFunction: "SMPTE_ST_2084_PQ", hasDolbyVisionConfig: false) == .dolbyVision)
        #expect(DynamicRange.classify(codecs: ["dva1"], transferFunction: nil, hasDolbyVisionConfig: false) == .dolbyVision)
        #expect(DynamicRange.classify(codecs: ["avc1"], transferFunction: "ITU_R_709_2", hasDolbyVisionConfig: false) == .sdr)
        #expect(DynamicRange.classify(codecs: [], transferFunction: nil, hasDolbyVisionConfig: false) == .sdr)
    }

    @Test func dolbyVisionConfigAtoms() {
        #expect(DynamicRange.containsDolbyVisionConfig(atomKeys: ["hvcC", "dvcC"]))
        #expect(DynamicRange.containsDolbyVisionConfig(atomKeys: ["dvvC"]))
        #expect(DynamicRange.containsDolbyVisionConfig(atomKeys: ["dvwC"]))
        #expect(!DynamicRange.containsDolbyVisionConfig(atomKeys: ["hvcC"]))
    }
}

@Suite struct EC3JOCTests {
    // data_rate 13 b + num_ind_sub 3 b (0 => ett oberoende delflöde).
    private let header: [UInt8] = [0x18, 0x00]

    @Test func jocFlagSet() {
        // Delflöde utan beroende delflöden: 24 bitar. Sedan reserverat 7 b + flag_ec3_extension_type_a 1 b + complexity 8 b.
        #expect(AVPlayerEngine.isEC3JOC(dec3: Data(header + [0x00, 0x00, 0x00] + [0x01, 0x10])))
    }

    @Test func jocFlagClear() {
        #expect(!AVPlayerEngine.isEC3JOC(dec3: Data(header + [0x00, 0x00, 0x00] + [0x00, 0x00])))
    }

    @Test func noExtensionFieldIsNotJOC() {
        #expect(!AVPlayerEngine.isEC3JOC(dec3: Data(header + [0x00, 0x00, 0x00])))
        #expect(!AVPlayerEngine.isEC3JOC(dec3: Data()))
    }

    @Test func dependentSubstreamAddsChanLoc() {
        // num_dep_sub = 1 (bitar 19–22) => 9 bitar chan_loc, delflödet blir 32 bitar.
        #expect(AVPlayerEngine.isEC3JOC(dec3: Data(header + [0x00, 0x00, 0x02, 0x00] + [0x01, 0x10])))
        #expect(!AVPlayerEngine.isEC3JOC(dec3: Data(header + [0x00, 0x00, 0x02, 0x00] + [0x00, 0x10])))
    }
}

@MainActor final class RecordingDisplayCriteria: DisplayCriteriaSetting {
    var current: DisplayCriteria?
    var setCount = 0
    var requested = false
    var holdsRequest: Bool
    private var gate: CheckedContinuation<Void, Never>?

    init(holdsRequest: Bool) { self.holdsRequest = holdsRequest }

    func criteria(for asset: AVAsset) async -> DisplayCriteria? {
        requested = true
        if holdsRequest { await withCheckedContinuation { gate = $0 } }
        return .placeholder
    }

    func set(_ criteria: DisplayCriteria?) {
        current = criteria
        setCount += 1
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor @Suite(.serialized) struct DisplayCriteriaTests {
    @Test func appliedOnLoadAndResetOnClose() async throws {
        let url = try await TestMedia.makeMovie(seconds: 1)
        let fake = RecordingDisplayCriteria(holdsRequest: false)
        let e = AVPlayerEngine(displayCriteria: fake)
        try await e.load(url: url, startAt: nil)
        #expect(fake.current != nil)
        e.close()
        #expect(fake.current == nil)
    }

    @Test func closeDuringCriteriaLoadNeverSetsCriteria() async throws {
        let url = try await TestMedia.makeMovie(seconds: 1)
        let fake = RecordingDisplayCriteria(holdsRequest: true)
        let e = AVPlayerEngine(displayCriteria: fake)
        let load = Task { try await e.load(url: url, startAt: nil) }
        let deadline = ContinuousClock.now + .seconds(15)
        while !fake.requested, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fake.requested)
        e.close()
        fake.release()
        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(fake.current == nil)
        #expect(fake.setCount == 0)
        #expect(e.state == .idle)
    }
}

@MainActor @Suite struct FakeEngineTests {
    @Test func succeedingScriptLoadsAndRecords() async throws {
        let rec = EngineRecorder()
        let audio = [MediaTrack(id: "0", kind: .audio, languageCode: "sv", title: "Svenska", codec: "ec-3", channelCount: 6, isAtmos: false, isDefault: true, isForced: false)]
        let e = FakeEngine(kind: .vlc, script: .succeeding(duration: 42, audio: audio, subtitles: [], info: .unknown), recorder: rec)
        var states: [PlaybackState] = []
        e.onStateChange = { states.append($0) }
        let url = URL(string: "https://example.invalid/a.mkv")!
        try await e.load(url: url, startAt: 5)
        #expect(e.state == .playing)
        #expect(e.loadedURL == url)
        #expect(e.loadedStartAt == 5)
        #expect(e.duration == 42)
        #expect(e.audioTracks == audio)
        #expect(states.last == .playing)
        e.select(audioID: "0")
        e.select(subtitleID: "3")
        #expect(e.selectedAudioID == "0")
        #expect(e.selectedSubtitleID == "3")
        e.currentTime = 12
        #expect(e.currentTime == 12)
        e.close()
        #expect(e.state == .idle)
        #expect(e.closeCount == 1)
        #expect(rec.events == [.made(.vlc), .loaded(.vlc, startAt: 5), .closed(.vlc)])
        #expect(rec.kinds == [.vlc])
        #expect(rec.closeCount(.vlc) == 1)
        #expect(rec.closeCount(.avPlayer) == 0)
    }

    @Test func defaultSucceedingScript() async throws {
        let e = FakeEngine(kind: .avPlayer, script: .succeeding())
        try await e.load(url: URL(string: "https://example.invalid/a.mp4")!, startAt: nil)
        #expect(e.duration == 1000)
        #expect(e.audioTracks.isEmpty)
        #expect(e.subtitleTracks.isEmpty)
        #expect(e.videoInfo == .unknown)
    }

    @Test func failingScriptThrows() async {
        let e = FakeEngine(kind: .avPlayer, script: .failing(.unsupportedFormat))
        await #expect(throws: PlaybackFailure.unsupportedFormat) {
            try await e.load(url: URL(string: "https://example.invalid/a.mp4")!, startAt: nil)
        }
        #expect(e.state == .failed(.unsupportedFormat))
    }

    @Test func hangingScriptThrowsCancellationOnClose() async throws {
        let rec = EngineRecorder()
        let e = FakeEngine(kind: .vlc, script: .hanging, recorder: rec)
        let load = Task { try await e.load(url: URL(string: "https://example.invalid/a.mkv")!, startAt: nil) }
        while e.state != .loading { await Task.yield() }
        e.close()
        await #expect(throws: CancellationError.self) { try await load.value }
        #expect(e.state == .idle)
        #expect(rec.events == [.made(.vlc), .loaded(.vlc, startAt: nil), .closed(.vlc)])
    }
}
