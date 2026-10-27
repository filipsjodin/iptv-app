import Foundation
import Metadata
import SwiftUI
import Testing
import UIKit
@testable import IPTVApp

/// Bildpipelinen i minnet, utan nätverk. Förhämtning blir klar direkt eller ligger kvar tills `complete`, och
/// cachen kan tömmas per bild. Varje anrop registreras.
@MainActor
private final class InMemoryArtworkBackend: ArtworkBackend {
    var completesPrefetchImmediately = true
    private(set) var cache: [ArtworkRequest: UIImage] = [:]
    private(set) var pending: Set<ArtworkRequest> = []
    private(set) var started: [ArtworkRequest] = []
    private(set) var cancelled: [ArtworkRequest] = []
    private(set) var loads: [ArtworkRequest] = []
    private(set) var lookups: [ArtworkRequest] = []

    func cachedImage(for request: ArtworkRequest) -> UIImage? {
        lookups.append(request)
        return cache[request]
    }

    func image(for request: ArtworkRequest) async throws -> UIImage {
        loads.append(request)
        let image = UIImage()
        cache[request] = image
        return image
    }

    func startPrefetching(_ requests: [ArtworkRequest]) {
        started.append(contentsOf: requests)
        for request in requests {
            if completesPrefetchImmediately {
                cache[request] = UIImage()
            } else {
                pending.insert(request)
            }
        }
    }

    func stopPrefetching(_ requests: [ArtworkRequest]) {
        cancelled.append(contentsOf: requests)
        pending.subtract(requests)
    }

    /// Gör en pågående förhämtning klar (en avbruten blir aldrig klar).
    func complete(_ request: ArtworkRequest) {
        guard pending.remove(request) != nil else { return }
        cache[request] = UIImage()
    }

    func evict(_ request: ArtworkRequest) {
        cache[request] = nil
    }
}

private func url(_ name: String) -> URL {
    URL(string: "https://example.invalid/\(name).jpg")!
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

    @Test func prefetchedURLReportsCached() {
        let backend = InMemoryArtworkBackend()
        let pipeline = ArtworkPipeline(backend: backend)
        let a = url("a"), b = url("b")

        #expect(!pipeline.isCached(a, kind: .poster))
        pipeline.prefetch([a], kind: .poster)
        #expect(pipeline.isCached(a, kind: .poster))
        #expect(!pipeline.isCached(b, kind: .poster))

        // Redan cachade hämtas inte igen.
        pipeline.prefetch([a, b], kind: .poster)
        #expect(backend.started.map(\.url) == [a, b])
    }

    @Test func prefetchIsPerKind() {
        let backend = InMemoryArtworkBackend()
        let pipeline = ArtworkPipeline(backend: backend)
        let a = url("a")

        pipeline.prefetch([a], kind: .poster)
        #expect(pipeline.isCached(a, kind: .poster))
        #expect(!pipeline.isCached(a, kind: .backdrop))

        pipeline.prefetch([a], kind: .backdrop)
        #expect(backend.started == [ArtworkRequest(url: a, kind: .poster), ArtworkRequest(url: a, kind: .backdrop)])
    }

    @Test func cancelKeepsCachedAndStopsPending() {
        let backend = InMemoryArtworkBackend()
        backend.completesPrefetchImmediately = false
        let pipeline = ArtworkPipeline(backend: backend)
        let a = url("a"), b = url("b")
        let ra = ArtworkRequest(url: a, kind: .poster), rb = ArtworkRequest(url: b, kind: .poster)

        pipeline.prefetch([a, b], kind: .poster)
        #expect(!pipeline.isCached(a, kind: .poster))
        backend.complete(ra)
        #expect(pipeline.isCached(a, kind: .poster))

        pipeline.cancelPrefetch([a, b], kind: .poster)
        #expect(backend.cancelled == [ra, rb])
        // Den klara ligger kvar; den avbrutna blir aldrig klar.
        #expect(pipeline.isCached(a, kind: .poster))
        backend.complete(rb)
        #expect(!pipeline.isCached(b, kind: .poster))

        // `isCached` speglar cachen, inte vad som förhämtats.
        backend.evict(ra)
        #expect(!pipeline.isCached(a, kind: .poster))
    }

    @Test func sharedPrefetchIsCancelledWhenLastReleases() {
        let backend = InMemoryArtworkBackend()
        backend.completesPrefetchImmediately = false
        let pipeline = ArtworkPipeline(backend: backend)
        let a = url("a"), b = url("b")
        let ra = ArtworkRequest(url: a, kind: .poster), rb = ArtworkRequest(url: b, kind: .poster)

        // Två rader förhämtar samma bild; den begärs en gång.
        pipeline.prefetch([a, b], kind: .poster)
        pipeline.prefetch([a], kind: .poster)
        #expect(backend.started == [ra, rb])

        // Första raden släpper: `b` behövs inte längre, `a` behövs fortfarande av den andra.
        pipeline.cancelPrefetch([a, b], kind: .poster)
        #expect(backend.cancelled == [rb])
        #expect(backend.pending == [ra])

        // Andra raden släpper: nu avbryts `a`.
        pipeline.cancelPrefetch([a], kind: .poster)
        #expect(backend.cancelled == [rb, ra])
        #expect(backend.pending.isEmpty)

        // Obalanserat avbrott ignoreras; en ny förhämtning börjar om.
        pipeline.cancelPrefetch([a], kind: .poster)
        #expect(backend.cancelled == [rb, ra])
        pipeline.prefetch([a], kind: .poster)
        #expect(backend.started == [ra, rb, ra])
    }

    @Test func missingURLRendersPlaceholderWithoutRequest() async {
        let backend = InMemoryArtworkBackend()
        let pipeline = ArtworkPipeline(backend: backend)
        let view = ArtworkImage(url: nil, kind: .poster, placeholderSystemImage: "film", pipeline: pipeline)

        // Bygger vyn (body) och kör laddningen som `.task` gör.
        let renderer = ImageRenderer(content: view.frame(width: 100, height: 150))
        #expect(renderer.uiImage != nil)
        await view.load()

        #expect(backend.loads.isEmpty)
        #expect(backend.started.isEmpty)
        #expect(backend.lookups.isEmpty)
    }

    @Test func cachedImageIsShownWithoutLoading() async {
        let backend = InMemoryArtworkBackend()
        let pipeline = ArtworkPipeline(backend: backend)
        let a = url("c")
        pipeline.prefetch([a], kind: .poster)

        let view = ArtworkImage(url: a, kind: .poster, placeholderSystemImage: "film", pipeline: pipeline)
        // Bilden finns i minnet redan när vyn byggs: ingen platshållare och ingen hämtning.
        #expect(view.memoryCachedImage != nil)
        await view.load()
        #expect(backend.loads.isEmpty)

        // Samma adress som en annan sort finns inte i cachen.
        let backdrop = ArtworkImage(url: a, kind: .backdrop, placeholderSystemImage: "film", pipeline: pipeline)
        #expect(backdrop.memoryCachedImage == nil)
    }

    @Test func transientFailureIsRetriedOnce() {
        let key = ArtworkImage.LoadKey(url: url("a"), kind: .poster)
        let other = ArtworkImage.LoadKey(url: url("a"), kind: .backdrop)

        #expect(ArtworkImage.shouldLoad(key, after: nil))
        let once = ArtworkImage.Failure(key: key, transient: true, attempts: 1)
        #expect(ArtworkImage.shouldLoad(key, after: once))
        let twice = ArtworkImage.Failure(key: key, transient: true, attempts: 2)
        #expect(!ArtworkImage.shouldLoad(key, after: twice))
        let permanent = ArtworkImage.Failure(key: key, transient: false, attempts: 1)
        #expect(!ArtworkImage.shouldLoad(key, after: permanent))
        // Ett fel för en annan bild (här samma adress, annan sort) stoppar inte.
        #expect(ArtworkImage.shouldLoad(other, after: permanent))
    }

    @Test func loadErrorsAreClassified() {
        #expect(NukeArtworkBackend.classify(URLError(.timedOut)) == .transient)
        #expect(NukeArtworkBackend.classify(URLError(.notConnectedToInternet)) == .transient)
        #expect(NukeArtworkBackend.classify(URLError(.badURL)) == .permanent)
        #expect(NukeArtworkBackend.classify(URLError(.cancelled)) == nil)
        #expect(NukeArtworkBackend.classify(CancellationError()) == nil)
        #expect(NukeArtworkBackend.classify(statusCode: 503) == .transient)
        #expect(NukeArtworkBackend.classify(statusCode: 429) == .transient)
        #expect(NukeArtworkBackend.classify(statusCode: 404) == .permanent)
    }
}
