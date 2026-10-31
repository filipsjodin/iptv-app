import SwiftUI

/// Säsongsflikar och avsnitten i vald säsong som en horisontell, lat rad. Korten är färdigräknade
/// (`EpisodeCardData`), så ritningen gör inget arbete och bilderna går genom `ArtworkImage`.
struct EpisodeShelf: View {
    let seasons: [Int]
    @Binding var season: Int?
    let cards: [EpisodeCardData]
    let disabled: Bool
    let onPlay: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(seasons, id: \.self) { number in
                            SeasonTab(number: number, selected: number == season) { season = number }
                        }
                    }
                    .padding(.vertical, TitleShelf.focusPadding)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(cards) { card in
                        EpisodeCard(card: card) { onPlay(card.id) }
                            .disabled(disabled)
                    }
                }
                .padding(.vertical, TitleShelf.focusPadding)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

private struct SeasonTab: View {
    let number: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) { Text("Season \(number)") }
        Group {
            if selected {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct EpisodeCard: View {
    let card: EpisodeCardData
    let action: () -> Void

    #if os(tvOS)
    private static let width: CGFloat = 360
    #else
    private static let width: CGFloat = 220
    #endif

    var body: some View {
        let button = Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                still
                Text(verbatim: card.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                if let duration = card.durationText {
                    Text(verbatim: duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let overview = card.overview {
                    Text(verbatim: overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(width: Self.width, alignment: .leading)
        }
        #if os(tvOS)
        button.buttonStyle(.card)
        #else
        button.buttonStyle(.plain)
        #endif
    }

    private var still: some View {
        ArtworkImage(url: card.stillURL, kind: .still, placeholderSystemImage: "play.rectangle")
            .font(.title)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .bottom) {
                if card.fraction > 0 {
                    // Röd förloppslinje längst ned: spår och fylld del.
                    Rectangle().fill(.white.opacity(0.35)).frame(height: 4)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.red).frame(height: 4).scaleEffect(x: card.fraction, anchor: .leading)
                        }
                }
            }
            .overlay(alignment: .topTrailing) {
                if card.watched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .green)
                        .padding(8)
                        .accessibilityLabel(Text("Watched"))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
