#if !os(tvOS)
import SwiftUI

/// Bannern överst i biblioteket medan appen är offline. Syns bara då; försvinner när nätet är tillbaka.
struct OfflineBanner: View {
    let state: OfflineState?

    var body: some View {
        if let state, state.isOffline {
            Label("You're offline – showing downloads", systemImage: "wifi.slash")
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(.bar)
                .accessibilityElement(children: .combine)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
#endif
