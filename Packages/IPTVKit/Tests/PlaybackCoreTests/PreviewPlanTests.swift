import Foundation
import Testing
@testable import PlaybackCore

@Test func startSecondsTenPercentWithFloorAndCap() {
    #expect(PreviewPlan.startSeconds(duration: 7200) == 720)
    #expect(PreviewPlan.startSeconds(duration: 300) == 60)    // golv 60, tak 90 nås ej
    #expect(PreviewPlan.startSeconds(duration: 100) == 30)    // tak 30 % slår golvet
    #expect(PreviewPlan.startSeconds(duration: 600) == 60)    // 10 % = golvet exakt
    #expect(PreviewPlan.startSeconds(duration: 5400) == 540)
    #expect(PreviewPlan.startSeconds(duration: 7201.4) == 720) // hela sekunder
    #expect(PreviewPlan.startSeconds(duration: 7205) == 721)   // 720,5 avrundas från noll
}

@Test(arguments: [nil, 0, -5, Double.nan, Double.infinity, -Double.infinity] as [Double?])
func startSecondsUnknownDurationIs120(_ duration: Double?) {
    #expect(PreviewPlan.startSeconds(duration: duration) == 120)
}

private func decide(enabled: Bool = true, kids: Bool = true, container: String? = "mp4",
                    active: Bool = false, lease: Bool = true) -> PreviewDecision {
    PreviewEligibility.decide(settingsEnabled: enabled, kidsAllowed: kids, container: container,
                              playbackActive: active, leaseGranted: lease)
}

@Test func eligibilityOrderAndContainers() {
    #expect(decide() == .play)
    for c in ["mp4", "m4v", "mov", "m3u8", "MP4", ".mp4", ".M3U8"] {
        #expect(decide(container: c) == .play, "container \(c)")
    }
    for c in ["mkv", "avi", "webm", "ts", "", nil, ".mkv"] as [String?] {
        #expect(decide(container: c) == .artwork(reason: .unsupportedContainer), "container \(String(describing: c))")
    }
    #expect(decide(active: true) == .artwork(reason: .connectionBusy))
    #expect(decide(lease: false) == .artwork(reason: .connectionBusy))
    // ordningen: disabled > kidsDenied > unsupportedContainer > connectionBusy
    #expect(decide(enabled: false, kids: false, container: "mkv", active: true, lease: false)
            == .artwork(reason: .disabled))
    #expect(decide(kids: false, container: "mkv", active: true, lease: false)
            == .artwork(reason: .kidsDenied))
    #expect(decide(container: "mkv", active: true, lease: false)
            == .artwork(reason: .unsupportedContainer))
    #expect(decide(container: nil, active: true) == .artwork(reason: .unsupportedContainer))
}

@Test func settleGateOnlyReportsAfterSettle() {
    let t0 = ContinuousClock.now
    var gate = FocusSettleGate()
    #expect(gate.settledID(at: t0) == nil)                       // inget fokus
    gate.focus("a", at: t0)
    #expect(gate.settledID(at: t0) == nil)
    #expect(gate.settledID(at: t0 + .milliseconds(1400)) == nil)
    #expect(gate.settledID(at: t0 + .milliseconds(1500)) == "a")
    #expect(gate.settledID(at: t0 + .seconds(10)) == "a")
    // samma id igen senare nollställer inte klockan
    gate.focus("a", at: t0 + .milliseconds(1000))
    #expect(gate.settledID(at: t0 + .milliseconds(1500)) == "a")
    // byte av id nollställer
    gate.focus("b", at: t0 + .milliseconds(2000))
    #expect(gate.settledID(at: t0 + .milliseconds(3400)) == nil)
    #expect(gate.settledID(at: t0 + .milliseconds(3500)) == "b")
    // inget fokus nollställer
    gate.clear()
    #expect(gate.settledID(at: t0 + .seconds(60)) == nil)
    gate.focus("b", at: t0 + .seconds(61))
    #expect(gate.settledID(at: t0 + .seconds(61)) == nil)
}

@Test func settleGateCustomSettle() {
    let t0 = ContinuousClock.now
    var gate = FocusSettleGate(settle: .milliseconds(200))
    gate.focus("x", at: t0)
    #expect(gate.settledID(at: t0 + .milliseconds(199)) == nil)
    #expect(gate.settledID(at: t0 + .milliseconds(200)) == "x")
}

@Test func previewSoundDefaultsTrueForLegacyBlob() throws {
    let legacy = Data(#"{"engine":"vlc","previewsEnabled":false}"#.utf8)
    let s = try JSONDecoder().decode(PlaybackSettings.self, from: legacy)
    #expect(s.previewSoundEnabled)
    #expect(!s.previewsEnabled && s.engine == .vlc)
    #expect(PlaybackSettings().previewSoundEnabled)

    var off = PlaybackSettings(); off.previewSoundEnabled = false
    let d = UserDefaults(suiteName: "test.\(UUID())")!
    off.save(to: d)
    #expect(PlaybackSettings.load(from: d).previewSoundEnabled == false)
    #expect(PlaybackSettings.load(from: d) == off)
}
