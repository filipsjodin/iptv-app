import SwiftUI
import UIKit

/// En bild ur `ArtworkPipeline` som fyller sin ram (beskärs till den). Utan adress, eller tills bilden finns,
/// visas en neutral platshållare med en symbol. Bilden är dekorativ; kortet runt den bär tillgänglighetsetiketten.
///
/// En bild som redan finns i minnescachen visas i första bildrutan, utan platshållare och utan övertoning. En
/// bild som måste hämtas tonas in kort (`Motion.imageFadeIn`, ingen övertoning med Minska rörelse). Ett tillfälligt
/// fel (nätverk, 5xx) försöks igen en gång när vyn visas på nytt; ett bestående fel (404, trasig bild) inte alls.
struct ArtworkImage: View {
    let url: URL?
    let kind: ArtworkKind
    let placeholderSystemImage: String
    /// `.fill` beskär till ramen (affischer); `.fit` visar hela bilden (kanalloggor).
    var displayMode: ContentMode = .fill
    private let pipeline: ArtworkPipeline

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Senast laddade bild och vad den hör till (adressen kan bytas, t.ex. när TMDB-affischen blir känd).
    @State private var loaded: Loaded?
    @State private var failure: Failure?

    struct LoadKey: Hashable {
        let url: URL
        let kind: ArtworkKind
    }

    struct Failure: Equatable {
        let key: LoadKey
        let transient: Bool
        /// Antal misslyckade försök i rad för `key`.
        let attempts: Int
    }

    private struct Loaded {
        let key: LoadKey
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

    func contentMode(_ mode: ContentMode) -> ArtworkImage {
        var copy = self
        copy.displayMode = mode
        return copy
    }

    private var key: LoadKey? { url.map { LoadKey(url: $0, kind: kind) } }

    var body: some View {
        Color.clear
            .overlay {
                if let image = currentImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: displayMode)
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
            .clipped()
            .task(id: key) { await load() }
    }

    private var placeholder: some View {
        Rectangle().fill(.quaternary)
            .overlay { Image(systemName: placeholderSystemImage).foregroundStyle(.secondary) }
    }

    /// Bilden för den aktuella adressen: den laddade, annars direkt ur minnescachen (ingen platshållare då).
    /// Byts adressen (t.ex. leverantörens affisch mot TMDB:s för samma titel) ligger den förra bilden kvar tills
    /// den nya finns, i stället för att blinka till platshållaren; misslyckas den nya ligger den förra kvar.
    private var currentImage: UIImage? {
        guard let key else { return nil }
        if let loaded, loaded.key == key { return loaded.image }
        return memoryCachedImage ?? loaded?.image
    }

    /// Bilden ur minnescachen (aldrig disk), eller `nil`. Ingen adress ger ingen uppslagning.
    var memoryCachedImage: UIImage? {
        guard let url else { return nil }
        return pipeline.cachedImage(url, kind: kind)
    }

    /// Om `key` ska hämtas efter `failure`: alltid efter ett fel för en annan bild, en gång till efter ett
    /// tillfälligt fel, aldrig efter ett bestående.
    static func shouldLoad(_ key: LoadKey, after failure: Failure?) -> Bool {
        guard let failure, failure.key == key else { return true }
        return failure.transient && failure.attempts < 2
    }

    /// Hämtar bilden om den inte redan visas. Utan adress görs ingen förfrågan. Körs när vyn visas och när
    /// adressen eller sorten byts.
    func load() async {
        guard let key else { return }
        if let loaded, loaded.key == key { return }
        if let cached = pipeline.cachedImage(key.url, kind: key.kind) {
            // Visas redan (ur cachen i `body`); spara utan animation så att den ligger kvar om cachen töms.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { loaded = Loaded(key: key, image: cached) }
            failure = nil
            return
        }
        guard Self.shouldLoad(key, after: failure) else { return }
        do {
            let image = try await pipeline.image(key.url, kind: key.kind)
            guard !Task.isCancelled else { return }
            failure = nil
            withAnimation(Motion.animation(Motion.imageFadeIn, reduceMotion: reduceMotion)) {
                loaded = Loaded(key: key, image: image)
            }
        } catch let error as ArtworkLoadError {
            guard !Task.isCancelled else { return }
            let previous = failure?.key == key ? failure?.attempts ?? 0 : 0
            failure = Failure(key: key, transient: error == .transient, attempts: previous + 1)
        } catch {
            // Avbrutet (vyn försvann eller adressen byttes): inget fel att minnas.
        }
    }
}
