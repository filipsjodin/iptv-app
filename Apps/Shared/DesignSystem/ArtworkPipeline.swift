import Foundation
import Metadata
import Nuke
import UIKit

/// Vilken sorts bild som visas. Styr TMDB-storleken som begärs och hur stor bilden avkodas i minnet.
enum ArtworkKind: Sendable, Hashable, CaseIterable {
    case poster, backdrop, logo, still

    /// TMDB-storleken som räcker för visningen.
    var tmdbSize: TMDBImage.Size {
        switch self {
        case .poster: .w342
        case .backdrop: .w1280
        case .logo: .w342
        case .still: .w780
        }
    }

    /// Största storlek (i pixlar) som bilden avkodas till. Leverantörers bilder kan vara mycket större än vad som
    /// visas; nedskalningen håller minnescachen liten och avkodningen snabb. Bilder förstoras aldrig.
    var maxPixelSize: CGSize {
        switch self {
        case .poster: CGSize(width: 600, height: 900)
        case .backdrop: CGSize(width: 1920, height: 1080)
        case .logo: CGSize(width: 800, height: 320)
        case .still: CGSize(width: 800, height: 450)
        }
    }
}

/// En bild att hämta: adressen och hur den ska visas.
struct ArtworkRequest: Hashable, Sendable {
    let url: URL
    let kind: ArtworkKind
}

/// Sömmen under `ArtworkPipeline`: håller avkodade bilder i minnet och hämtar dem. I appen Nuke
/// (`NukeArtworkBackend`); i tester en stub i minnet utan nätverk.
@MainActor
protocol ArtworkBackend: AnyObject, Sendable {
    /// Bilden ur minnescachen, eller `nil`. Billig nog att anropa i `body`.
    func cachedImage(for request: ArtworkRequest) -> UIImage?
    /// Hämtar bilden (minne, disk eller nätverk), avkodad och nedskalad.
    func image(for request: ArtworkRequest) async throws -> UIImage
    func startPrefetching(_ requests: [ArtworkRequest])
    func stopPrefetching(_ requests: [ArtworkRequest])
}

/// Appens enda väg till bilder. Resten av appen importerar inte Nuke; allt går via den här fasaden och
/// `ArtworkImage`.
@MainActor
struct ArtworkPipeline {
    let backend: any ArtworkBackend

    init(backend: any ArtworkBackend) {
        self.backend = backend
    }

    /// Diskcache (≤ 500 MB, i Caches) och minnescache (≤ 150 MB).
    static let shared = ArtworkPipeline(backend: NukeArtworkBackend())

    /// Värmer minnescachen för `urls` (t.ex. synliga rader ±1 skärm). Bilder som redan finns i minnet hoppas över.
    func prefetch(_ urls: [URL], kind: ArtworkKind = .poster) {
        let requests = urls.map { ArtworkRequest(url: $0, kind: kind) }
            .filter { backend.cachedImage(for: $0) == nil }
        guard !requests.isEmpty else { return }
        backend.startPrefetching(requests)
    }

    /// Avbryter förhämtning som inte är klar. Det som redan finns i cachen ligger kvar.
    func cancelPrefetch(_ urls: [URL], kind: ArtworkKind = .poster) {
        guard !urls.isEmpty else { return }
        backend.stopPrefetching(urls.map { ArtworkRequest(url: $0, kind: kind) })
    }

    /// Om bilden finns avkodad i minnet (visas då direkt, utan platshållare).
    func isCached(_ url: URL, kind: ArtworkKind = .poster) -> Bool {
        backend.cachedImage(for: ArtworkRequest(url: url, kind: kind)) != nil
    }

    func cachedImage(_ url: URL, kind: ArtworkKind) -> UIImage? {
        backend.cachedImage(for: ArtworkRequest(url: url, kind: kind))
    }

    func image(_ url: URL, kind: ArtworkKind) async throws -> UIImage {
        try await backend.image(for: ArtworkRequest(url: url, kind: kind))
    }
}

/// Nuke med diskcache i Caches och en begränsad minnescache.
///
/// tvOS har nästan inget beständigt lagringsutrymme: allt utom Caches kan saknas eller vara mycket litet, och
/// systemet kan tömma Caches när som helst. Diskcachen ligger därför i Caches, och om katalogen inte kan skapas
/// körs pipelinen utan diskcache (bara minne och nätverk) i stället för att krascha.
@MainActor
final class NukeArtworkBackend: ArtworkBackend {
    static let diskCacheName = "se.sjodin.iptv.artwork"
    static let diskCacheLimit = 500 * 1024 * 1024
    static let memoryCacheLimit = 150 * 1024 * 1024

    private let pipeline: ImagePipeline
    private let prefetcher: ImagePrefetcher

    init() {
        var configuration = ImagePipeline.Configuration()
        // Ingen URLCache: diskcachen ersätter den, så att bilderna inte lagras två gånger.
        let session = DataLoader.defaultConfiguration
        session.urlCache = nil
        configuration.dataLoader = DataLoader(configuration: session)
        if let dataCache = try? DataCache(name: Self.diskCacheName) {
            dataCache.sizeLimit = Self.diskCacheLimit
            configuration.dataCache = dataCache
        }
        // Originaldata på disk; varje visningsstorlek skalas från den utan ny nedladdning.
        configuration.dataCachePolicy = .storeOriginalData
        // Högst 150 MB, mindre på enheter med lite minne.
        let memoryLimit = min(Self.memoryCacheLimit, Int(clamping: ProcessInfo.processInfo.physicalMemory / 8))
        configuration.imageCache = ImageCache(costLimit: memoryLimit)
        pipeline = ImagePipeline(configuration: configuration)
        prefetcher = ImagePrefetcher(pipeline: pipeline, destination: .memoryCache, maxConcurrentRequestCount: 4)
    }

    func cachedImage(for request: ArtworkRequest) -> UIImage? {
        pipeline.cache[Self.imageRequest(request)]?.image
    }

    func image(for request: ArtworkRequest) async throws -> UIImage {
        try await pipeline.image(for: Self.imageRequest(request))
    }

    func startPrefetching(_ requests: [ArtworkRequest]) {
        prefetcher.startPrefetching(with: requests.map(Self.imageRequest))
    }

    func stopPrefetching(_ requests: [ArtworkRequest]) {
        prefetcher.stopPrefetching(with: requests.map(Self.imageRequest))
    }

    /// Samma förfrågan för visning och förhämtning, så att Nuke slår ihop dem och cachenycklarna stämmer.
    private static func imageRequest(_ request: ArtworkRequest) -> ImageRequest {
        ImageRequest(url: request.url, processors: [
            ImageProcessors.Resize(size: request.kind.maxPixelSize, unit: .pixels, contentMode: .aspectFill,
                                   crop: false, upscale: false),
        ])
    }
}
