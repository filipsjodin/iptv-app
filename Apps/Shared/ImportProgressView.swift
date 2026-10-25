import Core
import Library
import SwiftUI

/// Visar importfasen. Faserna saknar mätbar andel, så förloppet är obestämt tills importen är klar.
struct ImportProgressView: View {
    let phase: ImportPhase

    var body: some View {
        switch phase {
        case let .done(counts):
            Label("Imported \(counts[.movie] ?? 0) movies, \(counts[.series] ?? 0) series, \(counts[.live] ?? 0) channels",
                  systemImage: "checkmark.circle")
                .font(.footnote)
        default:
            ProgressView(label)
                .font(.footnote)
        }
    }

    private var label: LocalizedStringKey {
        switch phase {
        case .connecting: "Connecting…"
        case .downloading: "Downloading…"
        case .parsing: "Reading catalog…"
        case .saving: "Saving…"
        case .done: "Done"
        }
    }
}
