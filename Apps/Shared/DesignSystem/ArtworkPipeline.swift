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

/// En bild att hämta: adressen och hur den ska visas. Samma adress med olika sort är olika poster i cachen.
struct ArtworkRequest: Hashable, Sendable {
    let url: URL
    let kind: ArtworkKind
}

/// Varför en bild inte kunde hämtas.
enum ArtworkLoadError: Error, Equatable {
    /// Nätverket eller servern tillfälligt (tidsgräns, ingen anslutning, 5xx, 429): värt ett nytt försök.
    case transient
    /// Bilden finns inte eller går inte att avkoda (404, trasig data): inget nytt försök.
    case permanent
}

/// Sömmen under `ArtworkPipeline`: håller avkodade bilder i minnet och hämtar dem. I appen Nuke
/// (`NukeArtworkBackend`); i tester en stub i minnet utan nätverk.
@MainActor
protocol ArtworkBackend: AnyObject, Sendable {
    /// Bilden ur minnescachen, eller `nil`. Rör aldrig disk eller avkodning, så den får anropas i `body`.
    func cachedImage(for request: ArtworkRequest) -> UIImage?
    /// Hämtar bilden (minne, disk eller nätverk), avkodad och nedskalad. Kastar `ArtworkLoadError` eller
    /// `CancellationError`.
    func image(for request: ArtworkRequest) async throws -> UIImage
    func startPrefetching(_ requests: [ArtworkRequest])
    func stopPrefetching(_ requests: [ArtworkRequest])
}

/// Appens enda väg till bilder. Resten av appen importerar inte Nuke; allt går via den här fasaden och
/// `ArtworkImage`.
///
/// Förhämtning räknas per `(url, kind)`: flera rader kan förhämta samma bild, och den avbryts först när alla
/// som bett om den har avbrutit. Varje `prefetch` ska därför balanseras av ett `cancelPrefetch` med samma
/// adresser och sort.
@MainActor
struct ArtworkPipeline {
    let backend: any ArtworkBackend
    private let prefetches: PrefetchCounts

    init(backend: any ArtworkBackend) {
        self.backend = backend
        prefetches = PrefetchCounts()
    }

    /// Diskcache (≤ 500 MB, i Caches) och minnescache (≤ 150 MB).
    static let shared = ArtworkPipeline(backend: NukeArtworkBackend())

    /// Värmer minnescachen för `urls` (t.ex. synliga rader ±1 skärm). En bild som redan finns i minnet eller
    /// redan förhämtas begärs inte igen.
    func prefetch(_ urls: [URL], kind: ArtworkKind) {
        var start: [ArtworkRequest] = []
        for url in urls {
            let request = ArtworkRequest(url: url, kind: kind)
            if prefetches.retain(request), backend.cachedImage(for: request) == nil {
                start.append(request)
            }
        }
        guard !start.isEmpty else { return }
        backend.startPrefetching(start)
    }

    /// Släpper förhämtningen av `urls`. Den avbryts när ingen annan längre behöver den; det som redan finns i
    /// cachen ligger kvar. Adresser som inte förhämtas ignoreras.
    func cancelPrefetch(_ urls: [URL], kind: ArtworkKind) {
        let stop = urls.map { ArtworkRequest(url: $0, kind: kind) }.filter { prefetches.release($0) }
        guard !stop.isEmpty else { return }
        backend.stopPrefetching(stop)
    }

    /// Om bilden finns avkodad i minnet (visas då direkt, utan platshållare).
    func isCached(_ url: URL, kind: ArtworkKind) -> Bool {
        backend.cachedImage(for: ArtworkRequest(url: url, kind: kind)) != nil
    }

    func cachedImage(_ url: URL, kind: ArtworkKind) -> UIImage? {
        backend.cachedImage(for: ArtworkRequest(url: url, kind: kind))
    }

    func image(_ url: URL, kind: ArtworkKind) async throws -> UIImage {
        try await backend.image(for: ArtworkRequest(url: url, kind: kind))
    }
}

/// Hur många som förhämtar varje bild.
@MainActor
private final class PrefetchCounts {
    private var counts: [ArtworkRequest: Int] = [:]

    /// Räknar upp; `true` om det är den första.
    func retain(_ request: ArtworkRequest) -> Bool {
        let count = counts[request, default: 0] + 1
        counts[request] = count
        return count == 1
    }

    /// Räknar ner; `true` när den sista släppte. En bild som inte förhämtas ger `false`.
    func release(_ request: ArtworkRequest) -> Bool {
        guard let count = counts[request] else { return false }
        if count > 1 {
            counts[request] = count - 1
            return false
        }
        counts[request] = nil
        return true
    }
}

/// Nuke med diskcache i Caches och en begränsad minnescache.
///
/// Inget i `init` rör disken: diskcachen skapas först när den används (Nuke anropar den bara från sina egna köer)
/// och värms direkt på en bakgrundskö, så första bildrutan gör ingen disk-I/O på huvudtråden. tvOS har nästan
/// inget beständigt lagringsutrymme och systemet kan tömma Caches när som helst; diskcachen ligger därför i Caches,
/// och om katalogen inte kan skapas körs pipelinen utan diskcache (bara minne och nätverk).
@MainActor
final class NukeArtworkBackend: ArtworkBackend {
    static let diskCacheName = "se.sjodin.iptv.artwork"
    static let diskCacheLimit = 500 * 1024 * 1024
    static let memoryCacheLimit = 150 * 1024 * 1024
    /// Hur många färdiga `ImageRequest` som sparas innan sparlistan töms.
    private static let requestCacheLimit = 2048

    private let pipeline: ImagePipeline
    private let prefetcher: ImagePrefetcher
    /// En `ImageRequest` per bild, så att `body` inte bygger om förfrågan och dess processor varje gång.
    private var requests: [ArtworkRequest: ImageRequest] = [:]

    init() {
        var configuration = ImagePipeline.Configuration()
        // Ingen URLCache: diskcachen ersätter den, så att bilderna inte lagras två gånger.
        let session = URLSessionConfiguration.default
        session.urlCache = nil
        configuration.dataLoader = DataLoader(configuration: session)
        let dataCache = LazyDataCache(name: Self.diskCacheName, sizeLimit: Self.diskCacheLimit)
        configuration.dataCache = dataCache
        // Originaldata på disk; varje visningsstorlek skalas från den utan ny nedladdning.
        configuration.dataCachePolicy = .storeOriginalData
        // Högst 150 MB, mindre på enheter med lite minne.
        let memoryLimit = min(Self.memoryCacheLimit, Int(clamping: ProcessInfo.processInfo.physicalMemory / 8))
        configuration.imageCache = ImageCache(costLimit: memoryLimit)
        pipeline = ImagePipeline(configuration: configuration)
        prefetcher = ImagePrefetcher(pipeline: pipeline, destination: .memoryCache, maxConcurrentRequestCount: 4)
        DispatchQueue.global(qos: .utility).async { dataCache.warmUp() }
    }

    func cachedImage(for request: ArtworkRequest) -> UIImage? {
        pipeline.cache.cachedImage(for: imageRequest(request), caches: [.memory])?.image
    }

    func image(for request: ArtworkRequest) async throws -> UIImage {
        let nukeRequest = imageRequest(request)
        do {
            return try await pipeline.image(for: nukeRequest)
        } catch {
            guard let classified = Self.classify(error) else { throw CancellationError() }
            throw classified
        }
    }

    func startPrefetching(_ requests: [ArtworkRequest]) {
        prefetcher.startPrefetching(with: requests.map { imageRequest($0) })
    }

    func stopPrefetching(_ requests: [ArtworkRequest]) {
        prefetcher.stopPrefetching(with: requests.map { imageRequest($0) })
    }

    /// Samma förfrågan för visning och förhämtning, så att Nuke slår ihop dem och cachenycklarna stämmer.
    private func imageRequest(_ request: ArtworkRequest) -> ImageRequest {
        if let cached = requests[request] { return cached }
        if requests.count >= Self.requestCacheLimit { requests.removeAll(keepingCapacity: true) }
        let made = ImageRequest(url: request.url, processors: Self.processors[request.kind] ?? [])
        requests[request] = made
        return made
    }

    private static let processors: [ArtworkKind: [any ImageProcessing]] = Dictionary(
        uniqueKeysWithValues: ArtworkKind.allCases.map { kind in
            (kind, [ImageProcessors.Resize(size: kind.maxPixelSize, unit: .pixels, contentMode: .aspectFill,
                                           crop: false, upscale: false)])
        })

    /// Tillfälligt eller bestående fel; `nil` vid avbrott.
    nonisolated static func classify(_ error: any Error) -> ArtworkLoadError? {
        if error is CancellationError { return nil }
        if let error = error as? ImagePipeline.Error {
            // Avkodning, bearbetning, tom data: bilden blir inte bättre av ett nytt försök.
            guard let underlying = error.dataLoadingError else { return .permanent }
            return classify(underlying)
        }
        if let error = error as? DataLoader.Error, case let .statusCodeUnacceptable(code) = error {
            return classify(statusCode: code)
        }
        if let error = error as? URLError {
            if error.code == .cancelled { return nil }
            return transientURLErrors.contains(error.code) ? .transient : .permanent
        }
        return .transient
    }

    nonisolated static func classify(statusCode: Int) -> ArtworkLoadError {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode) ? .transient : .permanent
    }

    private nonisolated static let transientURLErrors: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive, .secureConnectionFailed,
        .backgroundSessionWasDisconnected,
    ]
}

/// Nukes `DataCache`, skapad först vid första användningen. Att skapa den läser och skriver på disk (katalog och
/// metadata), vilket inte får ske på huvudtråden.
private final class LazyDataCache: DataCaching, @unchecked Sendable {
    private let name: String
    private let sizeLimit: Int
    private let lock = NSLock()
    private var resolved = false
    private var cache: DataCache?

    init(name: String, sizeLimit: Int) {
        self.name = name
        self.sizeLimit = sizeLimit
    }

    func warmUp() { _ = base }

    /// Den riktiga cachen, eller `nil` om katalogen inte kunde skapas (då körs pipelinen utan diskcache).
    private var base: DataCache? {
        lock.lock()
        defer { lock.unlock() }
        if !resolved {
            resolved = true
            cache = try? DataCache(name: name)
            cache?.sizeLimit = sizeLimit
        }
        return cache
    }

    func cachedData(for key: String) -> Data? { base?.cachedData(for: key) }
    func containsData(for key: String) -> Bool { base?.containsData(for: key) ?? false }
    func storeData(_ data: Data, for key: String) { base?.storeData(data, for: key) }
    func removeData(for key: String) { base?.removeData(for: key) }
    func removeAll() { base?.removeAll() }
}
