import AVFoundation
import CoreVideo

public enum TestMedia {
    public enum Failure: Error { case writerFailed, pixelBufferFailed }

    /// Skapar en H.264-mp4 (128×128, 10 fps, enfärgade bildrutor) i en temporär katalog.
    public static func makeMovie(seconds: Int) async throws -> URL {
        let width = 128, height = 128
        let fps: Int32 = 10
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("testmedia-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw Failure.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, seconds) * Int(fps)
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let buffer = try makeFrame(width: width, height: height, shade: UInt8(truncatingIfNeeded: frame * 8))
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else {
                throw Failure.writerFailed
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writerFailed }
        return url
    }

    private static func makeFrame(width: Int, height: Int, shade: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let buffer else { throw Failure.pixelBufferFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.pixelBufferFailed }
        memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(buffer) * height)
        return buffer
    }
}
