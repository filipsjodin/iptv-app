import Foundation
import Metadata
import SwiftUI
import Testing
import UIKit
@testable import IPTVApp

/// Bildpipelinen i minnet: `prefetch` lägger bilden direkt i cachen, inget nätverk. Varje anrop registreras.
@MainActor
private final class InMemoryArtworkBackend: ArtworkBackend {
    private(set) var cache: [ArtworkRequest: UIImage] = [:]
    /// Förfrågningar som skickats vidare till "nätverket" (förhämtning eller laddning).
    private(set) var fetched: [ArtworkRequest] = []
    private(set) var cancelled: [ArtworkRequest] = []
    private(set) var lookups: [ArtworkRequest] = []

    func cachedImage(for request: ArtworkRequest) -> UIImage? {
        lookups.append(request)
        return cache[request]
    }

    func image(for request: ArtworkRequest) async throws -> UIImage {
        fetched.append(request)
        let image = UIImage()
        cache[request] = image
        return image
    }

    func startPrefetching(_ requests: [ArtworkRequest]) {
        for request in requests {
            fetched.append(request)
            cache[request] = UIImage()
        }
    }

    func stopPrefetching(_ requests: [ArtworkRequest]) {
        cancelled.append(contentsOf: requests)
    }
}

@MainActor
struct ArtworkPipelineTests {
    @Test func tmdbSizePerKind() {
        #expect(ArtworkKind.poster.tmdbSize == .w342)
        #expect(ArtworkKind.backdrop.tmdbSize == .w1280)
        #expect(ArtworkKind.logo.tmdbSize == .w342)
        #expect(ArtworkKind.still.tmdbSize == .w780)
    }

    @Test func motionIsNilUnderReduceMotion() {
        #expect(Motion.animation(Motion.focus, reduceMotion: true) == nil)
        #expect(Motion.animation(Motion.crossfade, reduceMotion: true) == nil)
        #expect(Motion.animation(Motion.focus, reduceMotion: false) == Motion.focus)
        #expect(Motion.animation(Motion.crossfade, reduceMotion: false) != nil)
    }

    @Test func prefetchedURLReportsCached() async throws {
        let backend = InMemoryArtworkBackend()
        let pipeline = ArtworkPipeline(backend: backend)
        let url = try #require(URL(string: "https://example.invalid/a.jpg"))
        let other = try #require(URL(string: "https://example.invalid/b.jpg"))

        #expect(!pipeline.isCached(url))
        pipeline.prefetch([url])
        #expect(pipeline.isCached(url))
        #expect(!pipeline.isCached(other))

        // Redan cachade hämtas inte igen.
        pipeline.prefetch([url, other])
        #expect(backend.fetched.map(\.url) == [url, other])

        // Avbruten förhämtning rör inte det som redan finns i cachen.
        pipeline.cancelPrefetch([url, other])
        #expect(pipeline.isCached(url))
        #expect(pipeline.isCached(other))
    }

    @Test func missingURLRendersPlaceholderWithoutRequest() async {
        let backend = InMemoryArtworkBackend()
        let pipeline = ArtworkPipeline(backend: backend)
        let view = ArtworkImage(url: nil, kind: .poster, placeholderSystemImage: "film", pipeline: pipeline)

        // Bygger vyn (body) och kör laddningen som `.task` gör.
        let renderer = ImageRenderer(content: view.frame(width: 100, height: 150))
        #expect(renderer.uiImage != nil)
        await view.load()

        #expect(backend.fetched.isEmpty)
        #expect(backend.lookups.isEmpty)
    }

    @Test func cachedImageIsShownWithoutLoading() async throws {
        let backend = InMemoryArtworkBackend()
        let pipeline = ArtworkPipeline(backend: backend)
        let url = try #require(URL(string: "https://example.invalid/c.jpg"))
        pipeline.prefetch([url])
        let fetchedBefore = backend.fetched.count

        let view = ArtworkImage(url: url, kind: .poster, placeholderSystemImage: "film", pipeline: pipeline)
        // Bilden finns i minnet redan när vyn byggs: ingen platshållare och ingen ny hämtning.
        #expect(view.memoryCachedImage != nil)
        await view.load()
        #expect(backend.fetched.count == fetchedBefore)
    }
}
