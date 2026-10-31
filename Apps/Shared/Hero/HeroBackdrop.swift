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
            // Utan hero (första laddningen, nekad titel, efter `reset`) eller utan bild: bara den mörka bakgrunden.
            // `ArtworkImage` skulle annars visa sin platshållarikon, som blinkar till vid varje tomt tillstånd.
            if let url = Self.imageURL(for: hero) {
                ArtworkImage(url: url, kind: kind, placeholderSystemImage: "film")
                    .animation(HeroModel.crossfade(reduceMotion: reduceMotion), value: url)
            }
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
