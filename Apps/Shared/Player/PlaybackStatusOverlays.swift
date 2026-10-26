import Playback
import SwiftUI

/// Felvy: vänligt meddelande, "Prova VLC"/"Prova Apples spelare" och "Stäng".
struct PlaybackErrorOverlay: View {
    let messageKey: String
    let model: PlayerScreenModel
    let onClose: () -> Void

    var body: some View {
        let alternative = model.alternativeEngine
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(LocalizedStringKey(messageKey))
                .multilineTextAlignment(.center)
            HStack {
                Button {
                    Task { await model.switchEngine(to: alternative) }
                } label: {
                    Text(alternative == .vlc ? "Try VLC" : "Try Apple's player")
                }
                .buttonStyle(.borderedProminent)
                // Samma motor igen (t.ex. när en kanal slutat sända).
                Button("Try Again") {
                    Task { await model.retry() }
                }
                Button("Close", action: onClose)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(tvOS)
        .onExitCommand(perform: onClose)
        #endif
    }
}

/// Laddningsindikator medan strömmen öppnas eller buffrar.
struct PlaybackLoadingOverlay: View {
    let state: PlaybackState

    var body: some View {
        if state == .loading || state == .buffering {
            // Täcker inte felvyns knappar: bara en indikator utan träffyta.
            ProgressView()
                .controlSize(.large)
                .allowsHitTesting(false)
        }
    }
}
