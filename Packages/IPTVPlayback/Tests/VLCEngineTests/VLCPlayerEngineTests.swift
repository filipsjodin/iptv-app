import Foundation
import Testing
import Playback
import PlaybackCore
import PlaybackTestSupport
@testable import VLCEngine

@MainActor @Suite(.serialized) struct VLCPlayerEngineTests {
    @Test(.timeLimit(.minutes(1))) func vlcPlaysGeneratedMovie() async throws {
        let url = try await TestMedia.makeMovie(seconds: 2)
        let e = VLCPlayerEngine(); try await e.load(url: url, startAt: nil)
        #expect(e.kind == .vlc)
        #expect(e.state == .playing || e.state == .paused); e.close()
        #expect(e.state == .idle)
    }

    @Test(.timeLimit(.minutes(1))) func missingFileFails() async {
        let e = VLCPlayerEngine(loadTimeout: .seconds(10))
        do {
            try await e.load(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).mkv"), startAt: nil)
            Issue.record("expected a failure")
        } catch let f as PlaybackFailure {
            #expect(e.state == .failed(f))
        } catch {
            Issue.record("expected PlaybackFailure")
        }
        e.close()
        #expect(e.state == .idle)
    }

    @Test(.timeLimit(.minutes(1))) func shortTimeoutFailsAsTimeoutOrNetwork() async {
        let e = VLCPlayerEngine(loadTimeout: .milliseconds(300))
        do {
            try await e.load(url: URL(string: "http://203.0.113.7:9/y.ts")!, startAt: nil)
            Issue.record("expected a failure")
        } catch let f as PlaybackFailure {
            #expect(f == .timeout || f == .network)
        } catch {
            Issue.record("expected PlaybackFailure")
        }
        e.close()
    }

    @Test(.timeLimit(.minutes(1))) func closeDuringLoadThrowsCancellation() async {
        let e = VLCPlayerEngine()
        let task = Task { @MainActor in
            try await e.load(url: URL(string: "http://203.0.113.7:9/z.ts")!, startAt: nil)
        }
        try? await Task.sleep(for: .milliseconds(200))
        e.close()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(e.state == .idle)
    }

    @Test func controlsAreNoOpsWhenIdle() async {
        let e = VLCPlayerEngine()
        e.play(); e.pause(); await e.seek(to: 5)
        e.select(audioID: "1"); e.select(subtitleID: nil)
        #expect(e.state == .idle)
        #expect(e.audioTracks.isEmpty && e.subtitleTracks.isEmpty)
        #expect(e.videoInfo == .unknown)
        #expect(e.currentTime == 0 && e.duration == nil)
    }

    @Test func playersUseSharedQuietLibrary() {
        // libvlc kan skriva hela MRL:en (med lösenord) i loggen: biblioteket ska vara tystat.
        #expect(VLCPlayerEngine.libraryOptions.contains("--quiet"))
        #expect(VLCPlayerEngine.quietLibraryIsSilent)
    }

    @Test(.timeLimit(.minutes(1))) func closeAndWaitReleasesPlayer() async throws {
        let url = try await TestMedia.makeMovie(seconds: 2)
        let e = VLCPlayerEngine()
        try await e.load(url: url, startAt: nil)
        #expect(e.playerUsesQuietLibrary)
        await e.closeAndWait()
        #expect(e.state == .idle)
        #expect(!e.isReleasePending)
    }

    @Test(.timeLimit(.minutes(1))) func closeAndWaitIsBoundedForUnresponsiveServer() async {
        // TEST-NET-3: anslutningen hänger. Stängningen får inte blockera huvudtråden eller vänta obegränsat.
        let e = VLCPlayerEngine(closeWaitLimit: .seconds(2))
        let task = Task { @MainActor in
            try await e.load(url: URL(string: "http://203.0.113.7:9/w.ts")!, startAt: nil)
        }
        try? await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        await e.closeAndWait()
        #expect(ContinuousClock.now - start < .seconds(3))
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(e.state == .idle)
    }
}
