import SwiftUI
import UIKit

/// En bild ur `ArtworkPipeline` som fyller sin ram (beskärs till den). Utan adress, eller tills bilden finns,
/// visas en neutral platshållare med en symbol.
///
/// En bild som redan finns i minnescachen visas i första bildrutan, utan platshållare och utan övertoning. En
/// bild som måste hämtas tonas in kort (`Motion.imageFadeIn`, ingen övertoning med Minska rörelse).
struct ArtworkImage: View {
    let url: URL?
    let kind: ArtworkKind
    let placeholderSystemImage: String
    private let pipeline: ArtworkPipeline

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Senast laddade bild och adressen den hör till (adressen kan bytas, t.ex. när TMDB-affischen blir känd).
    @State private var loaded: Loaded?

    private struct Loaded {
        let url: URL
        let image: UIImage
    }

    init(url: URL?, kind: ArtworkKind, placeholderSystemImage: String) {
        self.init(url: url, kind: kind, placeholderSystemImage: placeholderSystemImage, pipeline: .shared)
    }

    init(url: URL?, kind: ArtworkKind, placeholderSystemImage: String, pipeline: ArtworkPipeline) {
        self.url = url
        self.kind = kind
        self.placeholderSystemImage = placeholderSystemImage
        self.pipeline = pipeline
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image = currentImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
            .clipped()
            .task(id: url) { await load() }
    }

    private var placeholder: some View {
        Rectangle().fill(.quaternary)
            .overlay { Image(systemName: placeholderSystemImage).foregroundStyle(.secondary) }
    }

    /// Bilden för den aktuella adressen: den laddade, annars direkt ur minnescachen (ingen platshållare då).
    /// Byts adressen (t.ex. leverantörens affisch mot TMDB:s för samma titel) ligger den förra bilden kvar tills
    /// den nya finns, i stället för att blinka till platshållaren; misslyckas den nya ligger den förra kvar.
    private var currentImage: UIImage? {
        guard url != nil else { return nil }
        if let loaded, loaded.url == url { return loaded.image }
        return memoryCachedImage ?? loaded?.image
    }

    /// Bilden ur minnescachen, eller `nil`. Ingen adress ger ingen uppslagning.
    var memoryCachedImage: UIImage? {
        guard let url else { return nil }
        return pipeline.cachedImage(url, kind: kind)
    }

    /// Hämtar bilden om den inte redan visas. Utan adress görs ingen förfrågan.
    func load() async {
        guard let url else { return }
        if let loaded, loaded.url == url { return }
        if let cached = pipeline.cachedImage(url, kind: kind) {
            // Visas redan (ur cachen i `body`); spara utan animation så att den ligger kvar om cachen töms.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { loaded = Loaded(url: url, image: cached) }
            return
        }
        guard let image = try? await pipeline.image(url, kind: kind), !Task.isCancelled else { return }
        withAnimation(Motion.animation(Motion.imageFadeIn, reduceMotion: reduceMotion)) {
            loaded = Loaded(url: url, image: image)
        }
    }
}
