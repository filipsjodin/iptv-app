import Foundation

public enum DynamicRange: String, Sendable {
    case sdr, hdr10, hlg, dolbyVision

    var displayName: String? {
        switch self {
        case .sdr: return nil
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .dolbyVision: return "Dolby Vision"
        }
    }

    /// Klassar utifrån alla codec-FourCC (t.ex. "hvc1", "dvh1"), överföringsfunktion
    /// (värdet av `kCMFormatDescriptionExtension_TransferFunction`, t.ex. "SMPTE_ST_2084_PQ")
    /// och om en Dolby Vision-konfiguration (dvcC/dvvC/dvwC) finns. Dolby Vision vinner, så
    /// profil 8.x (hvc1 + dvcC med PQ- eller HLG-bas) rapporteras som Dolby Vision.
    public static func classify(codecs: [String], transferFunction: String?, hasDolbyVisionConfig: Bool) -> DynamicRange {
        if hasDolbyVisionConfig || codecs.contains(where: isDolbyVisionCodec) { return .dolbyVision }
        let t = (transferFunction ?? "").uppercased()
        if t.contains("2084") || t.contains("PQ") { return .hdr10 }
        if t.contains("HLG") || t.contains("2100") { return .hlg }
        return .sdr
    }

    /// dvh1, dvhe, dva1, dvav (även med profilsuffix, t.ex. "dvh1.08.07").
    public static func isDolbyVisionCodec(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return ["dvh1", "dvhe", "dva1", "dvav"].contains { c.hasPrefix($0) }
    }

    /// Sant om sample-description-tilläggen innehåller en Dolby Vision-konfigurationsbox.
    public static func containsDolbyVisionConfig(atomKeys: [String]) -> Bool {
        atomKeys.contains { ["dvcC", "dvvC", "dvwC"].contains($0) }
    }
}

public struct VideoInfo: Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    public var dynamicRange: DynamicRange
    public var videoCodec: String?
    public var audioDescription: String?
    public var bitrate: Double?
    public var frameRate: Double?

    public init(width: Int?, height: Int?, dynamicRange: DynamicRange, videoCodec: String?,
                audioDescription: String?, bitrate: Double?, frameRate: Double?) {
        self.width = width
        self.height = height
        self.dynamicRange = dynamicRange
        self.videoCodec = videoCodec
        self.audioDescription = audioDescription
        self.bitrate = bitrate
        self.frameRate = frameRate
    }

    /// SDR utan någon känd information.
    public static let unknown = VideoInfo(width: nil, height: nil, dynamicRange: .sdr, videoCodec: nil,
                                          audioDescription: nil, bitrate: nil, frameRate: nil)

    /// T.ex. "2160p · Dolby Vision · Atmos". Tom när inget är känt.
    public var summary: String {
        var parts: [String] = []
        if let height { parts.append("\(height)p") }
        if let name = dynamicRange.displayName { parts.append(name) }
        if let audioDescription, !audioDescription.isEmpty { parts.append(audioDescription) }
        return parts.joined(separator: " · ")
    }
}
