import AVFoundation
// AVKit: `AVPlayerItem.externalMetadata` (titeln i Kontrollcenter/AirPlay).
import AVKit
import CoreMedia
import PlaybackCore

/// Uppspelning via AVPlayer. `player` exponeras för `AVPlayerViewController`.
/// Loggar aldrig URL:er och lägger aldrig felsträngar i state.
@MainActor
public final class AVPlayerEngine: PlayerEngine {
    public let kind: EngineKind = .avPlayer
    public let player = AVPlayer()

    public private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public private(set) var duration: Double?
    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []
    public private(set) var selectedAudioID: String?
    public private(set) var selectedSubtitleID: String?
    public private(set) var videoInfo: VideoInfo = .unknown
    public var onStateChange: ((PlaybackState) -> Void)?

    public var currentTime: Double {
        let s = player.currentTime().seconds
        return s.isFinite ? s : 0
    }

    private let loadTimeout: Duration
    /// Titeln som visas i Kontrollcenter/AirPlay (`externalMetadata`). Aldrig URL:en.
    private let title: String?
    /// Aktuell tillgång; behålls så att pågående laddningar kan avbrytas (`cancelLoading()`) vid teardown.
    private var asset: AVURLAsset?
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: (any NSObjectProtocol)?
    /// Ökas vid varje load/close så att en avbruten laddning inte skriver över nyare state.
    private var generation = 0
    private var isActive = false
    private let displayCriteria: any DisplayCriteriaSetting
    /// Sant när den här motorn har satt skärmkriterier som ska återställas vid teardown.
    private var criteriaApplied = false

    /// - Parameter title: visas i Kontrollcenter och på AirPlay-mottagare. Ange aldrig en URL.
    public init(title: String? = nil, loadTimeout: Duration = .seconds(15),
                displayCriteria: any DisplayCriteriaSetting = SystemDisplayCriteria()) {
        self.title = title
        self.loadTimeout = loadTimeout
        self.displayCriteria = displayCriteria
        player.appliesMediaSelectionCriteriaAutomatically = false
    }

    isolated deinit {
        tearDown()
    }

    // MARK: - Laddning

    /// Kastar `PlaybackFailure`, eller `CancellationError` om laddningen ersätts av `close()`/ny `load` eller avbryts.
    public func load(url: URL, startAt: Double?) async throws {
        generation += 1
        let gen = generation
        tearDown()
        state = .loading

        let asset = AVURLAsset(url: url)
        self.asset = asset
        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = Self.externalMetadata(title: title)
        player.replaceCurrentItem(with: item)

        do {
            try await waitUntilReady(item, deadline: .now + loadTimeout, generation: gen)

            let durationTime = try? await asset.load(.duration)
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            let variants = (try? await asset.load(.variants)) ?? []
            let audio = await Self.tracks(in: audible, kind: .audio, variants: variants, asset: asset)
            let subtitles = await Self.tracks(in: legible, kind: .subtitle, variants: [], asset: nil)
            var info = await Self.inspectVideo(asset: asset, variants: variants)
            try checkCurrent(gen)

            if let startAt, startAt > 0 {
                await seekExact(startAt)
                try checkCurrent(gen)
            }
            // Kriterierna sätts först efter generationskontrollen, utan await emellan,
            // så att en close() under laddningen aldrig följs av att kriterier sätts.
            let criteria = await displayCriteria.criteria(for: asset)
            try checkCurrent(gen)
            if let criteria {
                displayCriteria.set(criteria)
                criteriaApplied = true
            }

            duration = Self.seconds(durationTime)
            audibleGroup = audible
            legibleGroup = legible
            audioTracks = audio
            subtitleTracks = subtitles
            selectedAudioID = selectedID(in: audible, item: item)
            selectedSubtitleID = selectedID(in: legible, item: item)
            let size = item.presentationSize
            if size.width > 0, size.height > 0 {
                info.width = Int(size.width.rounded())
                info.height = Int(size.height.rounded())
            }
            info.audioDescription = Self.audioDescription(for: audio.first { $0.id == selectedAudioID })
            videoInfo = info

            installObservers(for: item)
            isActive = true
            player.play()
            state = .playing
        } catch let failure as PlaybackFailure {
            if gen == generation {
                tearDown()
                state = .failed(failure)
            }
            throw failure
        } catch {
            if gen == generation {
                tearDown()
                state = .idle
            }
            throw error
        }
    }

    private func checkCurrent(_ gen: Int) throws {
        guard gen == generation else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func waitUntilReady(_ item: AVPlayerItem, deadline: ContinuousClock.Instant, generation gen: Int) async throws {
        while true {
            try checkCurrent(gen)
            switch item.status {
            case .readyToPlay: return
            case .failed: throw Self.failure(for: item.error)
            default: break
            }
            if player.status == .failed { throw Self.failure(for: player.error) }
            if ContinuousClock.now >= deadline { throw PlaybackFailure.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Styrning

    public func play() {
        guard isActive else { return }
        if state == .ended {
            player.seek(to: .zero)
        }
        player.play()
        state = .playing
    }

    public func pause() {
        guard isActive else { return }
        player.pause()
        state = .paused
    }

    public func seek(to seconds: Double) async {
        guard isActive else { return }
        await seekExact(seconds)
        if state == .ended { state = .paused }
    }

    private func seekExact(_ seconds: Double) async {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable _ in
                c.resume()
            }
        }
    }

    public func select(audioID: String?) {
        guard let item = player.currentItem, let group = audibleGroup else { return }
        guard let option = Self.option(audioID, in: group) else {
            if audioID == nil, group.allowsEmptySelection {
                item.select(nil, in: group)
                selectedAudioID = nil
                videoInfo.audioDescription = nil
            }
            return
        }
        item.select(option, in: group)
        selectedAudioID = audioID
        videoInfo.audioDescription = Self.audioDescription(for: audioTracks.first { $0.id == audioID })
    }

    public func select(subtitleID: String?) {
        guard let item = player.currentItem, let group = legibleGroup else { return }
        if let option = Self.option(subtitleID, in: group) {
            item.select(option, in: group)
            selectedSubtitleID = subtitleID
        } else if subtitleID == nil {
            item.select(nil, in: group)
            selectedSubtitleID = nil
        }
    }

    public func close() {
        generation += 1
        tearDown()
        state = .idle
    }

    // MARK: - Observatörer

    private func installObservers(for item: AVPlayerItem) {
        let refresh: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.refreshState() }
        }
        observations = [
            player.observe(\.timeControlStatus, options: [.new]) { @Sendable _, _ in refresh() },
            item.observe(\.status, options: [.new]) { @Sendable _, _ in refresh() },
        ]
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { @Sendable [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.markEnded() }
        }
    }

    private func refreshState() {
        guard isActive, let item = player.currentItem else { return }
        if item.status == .failed {
            state = .failed(Self.failure(for: item.error))
            return
        }
        if case .failed = state { return }
        switch player.timeControlStatus {
        case .playing: state = .playing
        case .waitingToPlayAtSpecifiedRate: state = .buffering
        case .paused: if state != .ended { state = .paused }
        @unknown default: break
        }
    }

    private func markEnded() {
        guard isActive else { return }
        state = .ended
    }

    private func tearDown() {
        isActive = false
        if criteriaApplied {
            displayCriteria.set(nil)
            criteriaApplied = false
        }
        observations.forEach { $0.invalidate() }
        observations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        // Avbryter pågående nyckelladdningar så att anslutningen till servern släpps direkt (max_connections == 1).
        asset?.cancelLoading()
        asset = nil
        duration = nil
        audibleGroup = nil
        legibleGroup = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioID = nil
        selectedSubtitleID = nil
        videoInfo = .unknown
    }

    /// Bara titeln (common identifier title); URL:en exponeras aldrig utåt.
    public nonisolated static func externalMetadata(title: String?) -> [AVMetadataItem] {
        guard let title, !title.isEmpty else { return [] }
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        item.extendedLanguageTag = "und"
        return [item]
    }

    private func selectedID(in group: AVMediaSelectionGroup?, item: AVPlayerItem) -> String? {
        guard let group, let selected = item.currentMediaSelection.selectedMediaOption(in: group),
              let index = group.options.firstIndex(of: selected) else { return nil }
        return "\(index)"
    }

    // MARK: - Felmappning

    private nonisolated static let unsupportedCodes: Set<Int> = Set([
        AVError.Code.fileFormatNotRecognized,
        .fileFailedToParse,
        .decoderNotFound,
        .decodeFailed,
        .undecodableMediaData,
    ].map(\.rawValue))

    private nonisolated static let fileURLCodes: Set<Int> = [
        NSURLErrorFileDoesNotExist, NSURLErrorFileIsDirectory, NSURLErrorNoPermissionsToReadFile,
    ]

    /// POSIX-fel som betyder nätverksproblem (ENETDOWN, ENETUNREACH, ECONNRESET, ETIMEDOUT, ECONNREFUSED, EHOSTUNREACH).
    private nonisolated static let posixNetworkCodes: Set<Int> = [50, 51, 54, 60, 61, 65]

    /// Mappar ett fel (inklusive underliggande fel) till `PlaybackFailure`. Felets text förs aldrig vidare.
    public nonisolated static func failure(for error: (any Error)?) -> PlaybackFailure {
        guard let error else { return .unknown }
        var chain: [NSError] = []
        var next: NSError? = error as NSError
        while let e = next, chain.count < 8 {
            chain.append(e)
            next = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let isNetwork = chain.contains { e in
            (e.domain == NSURLErrorDomain && !fileURLCodes.contains(e.code))
                || (e.domain == NSPOSIXErrorDomain && posixNetworkCodes.contains(e.code))
        }
        if isNetwork { return .network }
        if chain.contains(where: { $0.domain == AVFoundationErrorDomain && unsupportedCodes.contains($0.code) }) {
            return .unsupportedFormat
        }
        return .unknown
    }

    // MARK: - Inspektion

    private nonisolated static func seconds(_ time: CMTime?) -> Double? {
        guard let time, time.isValid, !time.isIndefinite else { return nil }
        let s = time.seconds
        return s.isFinite && s > 0 ? s : nil
    }

    private nonisolated static func option(_ id: String?, in group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        guard let id, let index = Int(id), group.options.indices.contains(index) else { return nil }
        return group.options[index]
    }

    nonisolated static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func audioDescription(for track: MediaTrack?) -> String? {
        guard let track else { return nil }
        if track.isAtmos { return "Atmos" }
        switch track.channelCount {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return nil
        }
    }

    private nonisolated static func tracks(in group: AVMediaSelectionGroup?, kind: TrackKind,
                                           variants: [AVAssetVariant], asset: AVURLAsset?) async -> [MediaTrack] {
        guard let group else { return [] }
        let options = group.options
        // AVAssetTrack är inte Sendable; spåren laddas här i stället för att skickas in.
        let assetTracks = kind == .audio ? ((try? await asset?.loadTracks(withMediaType: .audio)) ?? []) : []
        var result: [MediaTrack] = []
        for (index, option) in options.enumerated() {
            var channels: Int?
            var atmos = false
            if kind == .audio {
                (channels, atmos) = await audioDetails(option: option, index: index, optionCount: options.count,
                                                       variants: variants, assetTracks: assetTracks)
            }
            let codec = option.mediaSubTypes.first.map { fourCC($0.uint32Value) }
            result.append(MediaTrack(
                id: "\(index)",
                kind: kind,
                languageCode: option.extendedLanguageTag ?? option.locale?.identifier,
                title: option.displayName,
                codec: codec,
                channelCount: channels,
                isAtmos: atmos,
                isDefault: option == group.defaultOption,
                isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)))
        }
        return result
    }

    private nonisolated static func audioDetails(option: AVMediaSelectionOption, index: Int, optionCount: Int,
                                                 variants: [AVAssetVariant], assetTracks: [AVAssetTrack]) async -> (Int?, Bool) {
        // HLS: renditionsattribut per variant (CHANNELS="16/JOC" ger Atmos).
        for variant in variants {
            guard let attrs = variant.audioAttributes,
                  let rendition = attrs.renditionSpecificAttributes(for: option) else { continue }
            let rawChannels: Int? = rendition.channelCount
            let channels = rawChannels.flatMap { $0 > 0 ? $0 : nil }
            let isEC3 = attrs.formatIDs.contains(kAudioFormatEnhancedAC3)
            return (channels, rendition.isImmersive || (isEC3 && (channels ?? 0) >= 16))
        }
        // Fil: alternativ i spårordning när antalen stämmer.
        guard assetTracks.count == optionCount,
              let fd = try? await assetTracks[index].load(.formatDescriptions).first else { return (nil, false) }
        return audioDetails(of: fd)
    }

    /// E-AC-3 JOC (Atmos) känns igen på Atmos-kanallayout eller fler än 8 kanaler i formatbeskrivningen.
    private nonisolated static func audioDetails(of fd: CMFormatDescription) -> (Int?, Bool) {
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee
        let channels = asbd.map { Int($0.mChannelsPerFrame) }.flatMap { $0 > 0 ? $0 : nil }
        let isEC3 = fd.mediaSubType.rawValue == kAudioFormatEnhancedAC3
        var layoutSize = 0
        let tag = CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: &layoutSize)?.pointee.mChannelLayoutTag
        let atmosTags: Set<AudioChannelLayoutTag> = [
            kAudioChannelLayoutTag_Atmos_5_1_2, kAudioChannelLayoutTag_Atmos_7_1_4, kAudioChannelLayoutTag_Atmos_9_1_6,
        ]
        let atmosLayout = tag.map { atmosTags.contains($0) } ?? false
        let joc = (extensionAtoms(fd)?["dec3"] as? Data).map { isEC3JOC(dec3: $0) } ?? false
        return (channels, isEC3 && (joc || atmosLayout || (channels ?? 0) > 8))
    }

    private nonisolated static func extensionAtoms(_ fd: CMFormatDescription) -> [String: Any]? {
        CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any]
    }

    /// Läser `flag_ec3_extension_type_a` (JOC, dvs. Atmos) ur innehållet i en `dec3`-box
    /// (ETSI TS 102 366 bilaga F.6). Saknas tilläggsfältet blir svaret false.
    public nonisolated static func isEC3JOC(dec3: Data) -> Bool {
        var reader = BitReader(bytes: [UInt8](dec3))
        guard reader.skip(13), let independent = reader.read(3) else { return false }
        for _ in 0...independent {
            // fscod 2, bsid 5, reserved 1, asvc 1, bsmod 3, acmod 3, lfeon 1, reserved 3
            guard reader.skip(19), let dependent = reader.read(4) else { return false }
            guard reader.skip(dependent > 0 ? 9 : 1) else { return false }
        }
        guard reader.skip(7), let flag = reader.read(1) else { return false }
        return flag == 1
    }

    private nonisolated static func inspectVideo(asset: AVURLAsset, variants: [AVAssetVariant]) async -> VideoInfo {
        var info = VideoInfo.unknown
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let geometry = try? await track.load(.naturalSize, .preferredTransform) {
                let rect = CGRect(origin: .zero, size: geometry.0).applying(geometry.1)
                if rect.width != 0, rect.height != 0 {
                    info.width = Int(abs(rect.width).rounded())
                    info.height = Int(abs(rect.height).rounded())
                }
            }
            var codec: String?
            var transfer: String?
            var hasDolbyVisionConfig = false
            if let fd = try? await track.load(.formatDescriptions).first {
                codec = fourCC(fd.mediaSubType.rawValue)
                transfer = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                // Dolby Vision profil 8.x: hvc1/avc1 med en dvcC/dvvC/dvwC-konfiguration.
                hasDolbyVisionConfig = DynamicRange.containsDolbyVisionConfig(atomKeys: extensionAtoms(fd).map { Array($0.keys) } ?? [])
            }
            let characteristics = (try? await track.load(.mediaCharacteristics)) ?? []
            var range = DynamicRange.classify(codecs: codec.map { [$0] } ?? [], transferFunction: transfer,
                                              hasDolbyVisionConfig: hasDolbyVisionConfig)
            if range == .sdr, characteristics.contains(.containsHDRVideo) { range = .hdr10 }
            info.videoCodec = codec
            info.dynamicRange = range
            if let fps = try? await track.load(.nominalFrameRate), fps > 0 { info.frameRate = Double(fps) }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 { info.bitrate = Double(rate) }
        } else if let variant = variants.filter({ $0.videoAttributes != nil })
                    .max(by: { ($0.peakBitRate ?? 0) < ($1.peakBitRate ?? 0) }),
                  let video = variant.videoAttributes {
            // HLS: högsta varianten beskriver innehållet.
            let codecs = video.codecTypes.map { fourCC($0) }
            let codec = codecs.first(where: DynamicRange.isDolbyVisionCodec) ?? codecs.first
            let transfer: String? = switch video.videoRange {
            case .pq: "SMPTE_ST_2084_PQ"
            case .hlg: "ITU_R_2100_HLG"
            default: nil
            }
            info.videoCodec = codec
            // AVAssetVariant exponerar inte SUPPLEMENTAL-CODECS; alla codec-typer och VIDEO-RANGE används.
            info.dynamicRange = DynamicRange.classify(codecs: codecs, transferFunction: transfer, hasDolbyVisionConfig: false)
            info.frameRate = video.nominalFrameRate
            info.bitrate = variant.averageBitRate ?? variant.peakBitRate
            if video.presentationSize.width > 0, video.presentationSize.height > 0 {
                info.width = Int(video.presentationSize.width.rounded())
                info.height = Int(video.presentationSize.height.rounded())
            }
        }
        return info
    }
}

/// Läser bitar med den mest signifikanta biten först.
struct BitReader {
    private let bytes: [UInt8]
    private var position = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> UInt32? {
        guard count <= 32, position + count <= bytes.count * 8 else { return nil }
        var value: UInt32 = 0
        for _ in 0..<count {
            let bit = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
            value = (value << 1) | UInt32(bit)
            position += 1
        }
        return value
    }

    mutating func skip(_ count: Int) -> Bool {
        guard position + count <= bytes.count * 8 else { return false }
        position += count
        return true
    }
}
