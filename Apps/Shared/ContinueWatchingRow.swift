import Playback
import SwiftUI

/// "Fortsätt titta" överst i spellistans bläddringsvy (en sektion i en `List`). Visas bara när det finns poster;
/// anroparen läser in posterna med `AppModel.continueWatching(playlistID:)` och spelar upp valet.
struct ContinueWatchingRow: View {
    let items: [ContinueWatchingItem]
    let onSelect: (ContinueWatchingItem) -> Void

    var body: some View {
        if !items.isEmpty {
            Section("Continue Watching") {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 16) {
                        ForEach(items) { item in
                            Button { onSelect(item) } label: { ContinueWatchingCard(item: item) }
                                #if os(tvOS)
                                .buttonStyle(.card)
                                #else
                                .buttonStyle(.plain)
                                #endif
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct ContinueWatchingCard: View {
    let item: ContinueWatchingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: item.posterURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: Self.width, height: Self.width * 0.56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            ProgressView(value: item.progressFraction)
            Text(verbatim: item.title).font(.subheadline).lineLimit(1)
            if let subtitle = item.subtitle {
                Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
    }

    #if os(tvOS)
    static let width: CGFloat = 300
    #else
    static let width: CGFloat = 160
    #endif
}

/// En spelare att visa i helskärm.
struct PlayerPresentation: Identifiable {
    let id = UUID()
    let request: PlaybackRequest
    /// Bara för avsnitt (se `AppModel.nextEpisodeProvider(for:)`).
    let nextEpisodeProvider: (@MainActor () async -> PlaybackRequest?)?
}

extension View {
    /// Visar `PlayerScreen` i helskärm för `item`.
    func playerCover(_ item: Binding<PlayerPresentation?>, playlistID: UUID,
                     onDismiss: (() -> Void)? = nil) -> some View {
        fullScreenCover(item: item, onDismiss: onDismiss) { p in
            PlayerScreen(request: p.request, playlistID: playlistID, nextEpisodeProvider: p.nextEpisodeProvider)
        }
    }
}
