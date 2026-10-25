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

    /// Klassar utifrån codec-FourCC (t.ex. "dvh1") och överföringsfunktion
    /// (värdet av `kCMFormatDescriptionExtension_TransferFunction`, t.ex. "SMPTE_ST_2084_PQ").
    public static func classify(codec: String?, transferFunction: String?) -> DynamicRange {
        let c = (codec ?? "").lowercased()
        if c.hasPrefix("dvh") || c.hasPrefix("dva") || c == "dvav" { return .dolbyVision }
        let t = (transferFunction ?? "").uppercased()
        if t.contains("2084") || t.contains("PQ") { return .hdr10 }
        if t.contains("HLG") || t.contains("2100") { return .hlg }
        return .sdr
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
