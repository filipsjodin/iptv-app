import Playback
import SwiftUI

/// Kontroller för VLC: play/paus, skrubbningslist och de fyra menyerna. Systemets standardutseende.
///
/// tvOS: play/paus-knappen på fjärrkontrollen växlar, vänster/höger och svep på skrubbningslisten flyttar
/// ±10 s, Menu/Tillbaka stänger.
struct PlayerControlsOverlay: View {
    let model: PlayerScreenModel
    let onClose: () -> Void

    static let skipSeconds: Double = 10

    @State private var visible = true
    @State private var hideTask: Task<Void, Never>?
    /// Position under skrubbning; nil när motorns position visas.
    @State private var scrubPosition: Double?
    @State private var seekTask: Task<Void, Never>?
    #if os(tvOS)
    private enum Focus: Hashable { case progress }
    @FocusState private var focus: Focus?
    #endif

    var body: some View {
        #if os(iOS)
        ZStack {
            // Träffyta bakom kontrollerna, så att ett tryck tar fram dolda kontroller igen.
            Color.clear
                .contentShape(.rect)
                .onTapGesture {
                    if visible { visible = false } else { showTemporarily() }
                }
            controls
                .allowsHitTesting(visible)
        }
        #else
        controls
        #endif
    }

    @ViewBuilder
    private var controls: some View {
        let _ = model.tickCount
        let engine = model.session.engine
        let duration = engine?.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let position = scrubPosition ?? engine?.currentTime ?? 0
        let isPlaying = engine?.state == .playing || engine?.state == .buffering

        VStack {
            #if os(iOS)
            HStack {
                Button(action: onClose) {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            #endif
            Spacer()
            VStack(spacing: 16) {
                HStack {
                    Text(verbatim: Self.format(position))
                        .monospacedDigit()
                    progressBar(position: position, duration: duration)
                    Text(verbatim: duration.map(Self.format) ?? "")
                        .monospacedDigit()
                }
                HStack {
                    Button {
                        model.togglePlayPause()
                        showTemporarily()
                    } label: {
                        if isPlaying {
                            Label("Pause", systemImage: "pause.fill")
                        } else {
                            Label("Play", systemImage: "play.fill")
                        }
                    }
                    .labelStyle(.iconOnly)
                    Spacer()
                    PlayerMenuButtons(model: model)
                }
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .padding()
        }
        .opacity(visible ? 1 : 0)
        .animation(.default, value: visible)
        #if os(tvOS)
        .defaultFocus($focus, .progress)
        .onPlayPauseCommand {
            model.togglePlayPause()
            showTemporarily()
        }
        .onExitCommand(perform: onClose)
        #endif
        .onAppear { showTemporarily() }
        .onDisappear {
            hideTask?.cancel()
            seekTask?.cancel()
        }
    }

    @ViewBuilder
    private func progressBar(position: Double, duration: Double?) -> some View {
        #if os(tvOS)
        ProgressView(value: duration.map { min(max(position / $0, 0), 1) } ?? 0)
            .focusable(duration != nil)
            .focused($focus, equals: .progress)
            .onMoveCommand { direction in
                showTemporarily()
                switch direction {
                case .left: scrub(by: -Self.skipSeconds, duration: duration)
                case .right: scrub(by: Self.skipSeconds, duration: duration)
                default: break
                }
            }
        #else
        if let duration {
            Slider(value: Binding(get: { min(position, duration) },
                                  set: { scrubPosition = $0 }),
                   in: 0...duration,
                   onEditingChanged: { editing in
                       if editing {
                           hideTask?.cancel()
                       } else if let target = scrubPosition {
                           commitSeek(to: target, after: .zero)
                           showTemporarily()
                       }
                   })
        } else {
            ProgressView(value: 0).hidden()
        }
        #endif
    }

    /// Flyttar skrubbpositionen och söker när användaren slutat trycka/svepa en stund.
    private func scrub(by delta: Double, duration: Double?) {
        guard let duration else { return }
        let base = scrubPosition ?? model.session.engine?.currentTime ?? 0
        let target = min(max(base + delta, 0), duration)
        scrubPosition = target
        commitSeek(to: target, after: .milliseconds(600))
    }

    private func commitSeek(to target: Double, after delay: Duration) {
        seekTask?.cancel()
        seekTask = Task {
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await model.seek(to: target)
            scrubPosition = nil
        }
    }

    private func showTemporarily() {
        visible = true
        hideTask?.cancel()
        hideTask = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if model.session.engine?.state == .playing { visible = false }
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(0, Int(seconds)) : 0
        return Duration.seconds(s).formatted(.time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
