import SwiftUI

/// Uppgifterna om den fokuserade titeln ovanför raderna: logga (annars titeltext), betyg och åldersgräns, år,
/// speltid, kvalitetsmärken och en kort beskrivning (högst tre rader). Inga knappar: medan man bläddrar ligger fokus
/// på korten i raderna, så knappar här skulle inte gå att nå. Spela, Min lista och betyg finns på detaljsidan.
struct HeroInfoPanel: View {
    let hero: HeroInfo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeroTitle(hero: hero)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(HeroModel.crossfade(reduceMotion: reduceMotion), value: hero)
    }

    /// "1 tim 58 min" i användarens språk.
    static func runtimeText(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

/// Titelns logga (annars titeltexten). Delas av hero-panelen på Hem och detaljsidan.
struct HeroTitle: View {
    let hero: HeroInfo

    var body: some View {
        if let logo = hero.logoURL {
            // `.fit`: hela loggan skalas in i rutan (`.fill` beskär en logga som är större än rutan).
            ArtworkImage(url: logo, kind: .logo, placeholderSystemImage: "film")
                .contentMode(.fit)
                .contentAlignment(.bottomLeading)
                .frame(width: Self.logoSize.width, height: Self.logoSize.height, alignment: .leading)
                .accessibilityLabel(Text(verbatim: hero.title))
        } else {
            Text(verbatim: hero.title)
                .font(.largeTitle.bold())
                .lineLimit(2)
        }
    }

    #if os(tvOS)
    private static let logoSize = CGSize(width: 520, height: 150)
    #else
    private static let logoSize = CGSize(width: 260, height: 80)
    #endif
}
