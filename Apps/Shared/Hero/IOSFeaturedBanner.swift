#if !os(tvOS)
import Library
import SwiftUI

/// Bannern överst på Hem (iOS): titelns backdrop som stillbild (aldrig förhandsvisning, ingen video och ingen
/// anslutning), logga eller titel, betyg/år/speltid/kvalitetsmärken och knapparna Spela och Mer info.
/// Uppgifterna kommer från samma väg som tvOS-heron (`AppModel.hero`: databasläsning utanför huvudtråden, barnfilter,
/// cache); tills de kommit visas leverantörens titel och affisch. Bildformatet styrs av `isRegular`
/// (21:9 på bred yta, annars 16:9).
struct IOSFeaturedBanner: View {
    @Environment(AppModel.self) private var model
    let pick: FeaturedPick
    let playlistID: UUID
    let isRegular: Bool
    let onPlay: (Library.LibraryItem) -> Void

    @State private var hero: HeroInfo?

    private var aspect: Double { isRegular ? 21.0 / 9.0 : 16.0 / 9.0 }

    private var imageURL: URL? {
        hero.flatMap { HeroBackdrop.imageURL(for: $0) } ?? pick.item.posterURL
    }

    private var imageKind: ArtworkKind { hero?.backdropURL == nil ? .poster : .backdrop }

    var body: some View {
        Color.black
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    if let imageURL {
                        ArtworkImage(url: imageURL, kind: imageKind,
                                     placeholderSystemImage: pick.item.kind == .series ? "tv" : "film")
                            .accessibilityHidden(true)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    info.padding(16)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: pick.item.id) {
                hero = nil
                hero = await model.hero(for: pick.item, playlistID: playlistID)
            }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hero {
                HeroTitle(hero: hero)
                    .font(.title2.bold())
                details(hero)
            } else {
                Text(verbatim: pick.item.title).font(.title2.bold()).lineLimit(2)
            }
            HStack(spacing: 12) {
                Button { onPlay(pick.item) } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                NavigationLink {
                    TitleDestination(kind: pick.item.kind, providerID: pick.item.providerID, playlistID: playlistID,
                                     preview: nil, item: pick.item)
                } label: {
                    Label("More Info", systemImage: "info.circle")
                }
                .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func details(_ hero: HeroInfo) -> some View {
        HStack(spacing: 12) {
            RatingsRow(ratings: hero.ratings, certification: hero.certification)
            if let year = hero.year {
                Text(verbatim: String(year))
            }
            if let minutes = hero.runtimeMinutes, minutes > 0 {
                Text(verbatim: HeroInfoPanel.runtimeText(minutes: minutes))
            }
            QualityBadgeRow(badges: hero.badges)
        }
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.8))
        .lineLimit(1)
    }
}
#endif
