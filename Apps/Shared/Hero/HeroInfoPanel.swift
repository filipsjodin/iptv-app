import SwiftUI

/// Uppgifterna om den fokuserade titeln ovanför raderna: logga (annars titeltext), betyg och åldersgräns, år,
/// speltid, kvalitetsmärken, en kort beskrivning (högst tre rader) och knapparna Spela, Min lista och 👍/👎.
/// Min lista och betyg skrivs till den aktiva profilens `PersonalStore` via `PersonalButtons`.
struct HeroInfoPanel: View {
    let hero: HeroInfo
    let onPlay: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            title
            HStack(spacing: 20) {
                RatingsRow(ratings: hero.ratings, certification: hero.certification)
                if let year = hero.year {
                    Text(verbatim: String(year))
                }
                if let minutes = hero.runtimeMinutes, minutes > 0 {
                    Text(verbatim: Self.runtimeText(minutes: minutes))
                }
                QualityBadgeRow(badges: hero.badges)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let overview = hero.overview {
                Text(verbatim: overview)
                    .font(.callout)
                    .lineLimit(3)
                    .frame(maxWidth: 900, alignment: .leading)
            }
            HStack(spacing: 20) {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                PersonalButtons(ref: hero.ref)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(HeroModel.crossfade(reduceMotion: reduceMotion), value: hero)
    }

    @ViewBuilder
    private var title: some View {
        if let logo = hero.logoURL {
            ArtworkImage(url: logo, kind: .logo, placeholderSystemImage: "film")
                .frame(width: 520, height: 150, alignment: .leading)
                .accessibilityLabel(Text(verbatim: hero.title))
        } else {
            Text(verbatim: hero.title)
                .font(.largeTitle.bold())
                .lineLimit(2)
        }
    }

    /// "1 tim 58 min" i användarens språk.
    static func runtimeText(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}
