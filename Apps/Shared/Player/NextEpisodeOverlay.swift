import SwiftUI

/// "Nästa avsnitt" med nedräkning. "Avbryt" stoppar nedräkningen; vid 0 startar nästa avsnitt.
struct NextEpisodeOverlay: View {
    let model: PlayerScreenModel

    var body: some View {
        if let seconds = model.countdown {
            HStack {
                Button("Cancel", role: .cancel) { model.cancelCountdown() }
                Button {
                    model.playNextEpisodeNow()
                } label: {
                    Text("Next episode (\(seconds))")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }
}
