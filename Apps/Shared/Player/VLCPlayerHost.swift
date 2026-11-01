import Playback
import PlaybackCore
import SwiftUI
import UIKit
import VLCEngine

/// VLC-motorns videoyta med SwiftUI-kontroller ovanpå. Titeln, tiden och fjärrkommandona visas i Kontrollcenter
/// via `NowPlayingController` medan vyn visas (Apples spelare sköter det själv och rör aldrig den här).
struct VLCPlayerHost: View {
    let engine: VLCPlayerEngine
    let model: PlayerScreenModel
    let onClose: () -> Void
    /// Falskt när något annat äger fjärrkontrollen (tvOS live med zappning).
    var showsControls = true
    var isLive = false

    var body: some View {
        ZStack {
            VLCDrawableView(drawable: engine.drawable)
                .ignoresSafeArea()
            if showsControls { PlayerControlsOverlay(model: model, onClose: onClose) }
            VLCNowPlayingBinder(engine: engine, model: model, isLive: isLive)
        }
    }
}

/// Fjärrkommandon till VLC-motorn. Håller motorn svagt; en stoppad motor styrs aldrig.
@MainActor
final class VLCNowPlayingCommands: NowPlayingCommands {
    private weak var engine: VLCPlayerEngine?
    private var seekTask: Task<Void, Never>?

    init(engine: VLCPlayerEngine) { self.engine = engine }

    func play() { engine?.play() }
    func pause() { engine?.pause() }

    func togglePlayPause() {
        guard let engine else { return }
        if engine.state == .playing || engine.state == .buffering { engine.pause() } else { engine.play() }
    }

    func skip(by seconds: Double) {
        guard let engine else { return }
        seek(to: engine.currentTime + seconds)
    }

    func seek(to seconds: Double) {
        guard let engine else { return }
        var target = max(0, seconds)
        if let duration = engine.duration, duration.isFinite, duration > 0 { target = min(target, duration) }
        seekTask?.cancel()
        seekTask = Task { [weak engine] in await engine?.seek(to: target) }
    }
}

/// Osynlig vy som håller Now Playing i takt med VLC-motorn: vid start, paus/spel, positionshopp och var 5:e
/// sekund. Rensar vid försvinnande bara som ägare (en ny motor kan ha tagit över).
private struct VLCNowPlayingBinder: View {
    let engine: VLCPlayerEngine
    let model: PlayerScreenModel
    let isLive: Bool

    @State private var controller: NowPlayingController?
    @State private var last: (playing: Bool, elapsed: Double, at: Date)?

    private static let refresh: TimeInterval = 5

    var body: some View {
        let tick = model.tickCount
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                let controller = NowPlayingController(commands: VLCNowPlayingCommands(engine: engine))
                self.controller = controller
                controller.start(owner: ObjectIdentifier(engine))
                controller.onPausedBySystemEvent = { last = nil }
                publish(force: true)
            }
            .onChange(of: tick) { publish(force: false) }
            .onDisappear {
                controller?.stop(owner: ObjectIdentifier(engine))
                controller = nil
            }
    }

    private func publish(force: Bool) {
        guard let controller, let title = engine.title, !title.isEmpty else { return }
        let playing = engine.state == .playing || engine.state == .buffering
        let elapsed = engine.currentTime
        let now = Date()
        if !force, let last {
            let expected = last.elapsed + (last.playing ? now.timeIntervalSince(last.at) : 0)
            let jumped = abs(elapsed - expected) > 2
            if playing == last.playing, !jumped, now.timeIntervalSince(last.at) < Self.refresh { return }
        }
        last = (playing, elapsed, now)
        let info = NowPlayingInfo(title: title, elapsed: elapsed, duration: engine.duration, isPlaying: playing,
                                  isLive: isLive)
        controller.update(info, owner: ObjectIdentifier(engine))
    }
}

/// Placerar motorns `drawable` i en behållare som följer vyns storlek.
struct VLCDrawableView: UIViewRepresentable {
    let drawable: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        drawable.frame = container.bounds
        drawable.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(drawable)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if drawable.superview !== container {
            drawable.frame = container.bounds
            container.addSubview(drawable)
        }
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        for view in container.subviews { view.removeFromSuperview() }
    }
}
