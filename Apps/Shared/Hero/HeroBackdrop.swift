import SwiftUI

/// Hems bakgrund på tvOS: titelns backdrop i helskärm (affischen när backdrop saknas), förhandsvisningen ovanpå när
/// den spelar, och en toning mot botten (och vänster) så att texten och raderna alltid är läsbara.
/// Byten av bild korsar med `Motion.crossfade`; under Minska rörelse byts de utan animation.
struct HeroBackdrop: View {
    let hero: HeroInfo?
    let preview: PreviewController?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bilden som visas för heron: backdrop, annars affisch (leverantörens eller TMDB:s), annars ingen.
    static func imageURL(for hero: HeroInfo?) -> URL? {
        guard let hero else { return nil }
        return hero.backdropURL ?? hero.posterURL
    }

    private var kind: ArtworkKind { hero?.backdropURL == nil ? .poster : .backdrop }

    var body: some View {
        ZStack {
            Color.black
            ArtworkImage(url: Self.imageURL(for: hero), kind: kind, placeholderSystemImage: "film")
                .animation(HeroModel.crossfade(reduceMotion: reduceMotion), value: Self.imageURL(for: hero))
            if let preview {
                PreviewSurface(controller: preview)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .center)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
