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

/// Diskret förslag nere i bild efter upprepad buffring i live: "Byt till lägre kvalitet?". Försvinner av sig själv
/// efter en stund. På tvOS accepterar Select (`ZapPressCatcher` äger fokus) och Menu avvisar; på iOS finns
/// knappar. Att bannern tonar ut av sig själv på tvOS räknas som ett avvisande (ingen knapp att avvisa med).
struct LowerQualitySuggestion: View {
    static let visibleSeconds = 10

    let model: PlayerScreenModel

    var body: some View {
        if let lower = model.suggestLower {
            VStack {
                Spacer()
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Switch to lower quality?")
                        Text(verbatim: lower.name).font(.caption).foregroundStyle(.secondary)
                    }
                    #if os(iOS)
                    Button("Switch") { Task { await model.acceptSuggestion() } }
                        .buttonStyle(.borderedProminent)
                    Button("Not now") { model.dismissSuggestion() }
                        .buttonStyle(.bordered)
                    #else
                    Text("Press Select to switch, Menu to dismiss").font(.caption).foregroundStyle(.secondary)
                    #endif
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.bottom, 48)
            }
            // Ett nytt förslag (annan variant) startar om nedräkningen.
            .task(id: lower.id) {
                do { try await Task.sleep(for: .seconds(Self.visibleSeconds)) } catch { return }
                #if os(tvOS)
                model.dismissSuggestion()
                #else
                model.hideSuggestion()
                #endif
            }
        }
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
