import Foundation
#if canImport(Compression)
import Compression
#endif

/// Uppackning av gzip-komprimerade filer (t.ex. EPG) utan att hela filen läses in i minnet.
public enum GzipFile {
    /// Högsta storlek på uppackat innehåll (2 GiB): skyddar mot en liten fil som packas upp till en full disk.
    public static let defaultMaxOutputBytes = 2 * 1024 * 1024 * 1024

    /// Sant om `total + adding` ryms inom `limit` (utan heltalsöverflöd).
    static func fits(total: Int, adding: Int, limit: Int) -> Bool {
        let (sum, overflow) = total.addingReportingOverflow(adding)
        return !overflow && sum <= limit
    }

    /// Längden på gzip-headern (inklusive valfria fält), eller `nil` om data inte börjar med
    /// gzip-magin `1F 8B` (deflate) eller är för kort för att headern ska kunna avgöras.
    public static func headerLength(_ prefix: Data) -> Int? {
        let b = [UInt8](prefix)
        guard b.count >= 10, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var pos = 10
        if flags & 0x04 != 0 {   // FEXTRA
            guard b.count >= pos + 2 else { return nil }
            pos += 2 + Int(b[pos]) + (Int(b[pos + 1]) << 8)
            guard b.count >= pos else { return nil }
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {   // FNAME, FCOMMENT
            guard let end = b[pos...].firstIndex(of: 0) else { return nil }
            pos = end + 1
        }
        if flags & 0x02 != 0 {   // FHCRC
            pos += 2
            guard b.count >= pos else { return nil }
        }
        return pos
    }

    /// Packar upp `source` till en temporär fil och returnerar den. Är filen inte gzip returneras `source`
    /// oförändrad. Anroparen tar bort en eventuell ny fil. Fel innehåller aldrig sökväg eller URL. Blir det uppackade
    /// innehållet större än `maxOutputBytes` avbryts uppackningen med `invalidResponse` och den halva filen tas bort.
    /// `directory` är var den uppackade filen skapas (tillfällig mapp som standard).
    public static func inflate(_ source: URL, maxOutputBytes: Int = defaultMaxOutputBytes,
                               directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) } catch { throw ProviderError.invalidResponse }
        defer { try? input.close() }
        let prefix: Data
        do { prefix = try input.read(upToCount: 64 * 1024) ?? Data() } catch { throw ProviderError.invalidResponse }
        let isGzipMagic = prefix.count >= 2 && prefix[prefix.startIndex] == 0x1F && prefix[prefix.startIndex + 1] == 0x8B
        guard isGzipMagic else { return source }
        guard let header = headerLength(prefix) else { throw ProviderError.invalidResponse }
        #if canImport(Compression)
        return try inflateDeflate(input: input, skipping: header, maxOutputBytes: maxOutputBytes, directory: directory)
        #else
        throw ProviderError.invalidResponse   // gzip stöds bara där Compression finns (Apple)
        #endif
    }

    #if canImport(Compression)
    private static func inflateDeflate(input: FileHandle, skipping header: Int, maxOutputBytes: Int,
                                       directory: URL) throws -> URL {
        let out = directory.appendingPathComponent("epg-\(UUID().uuidString).xml")
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let output = try? FileHandle(forWritingTo: out) else { throw ProviderError.invalidResponse }
        var succeeded = false
        defer {
            try? output.close()
            if !succeeded { try? FileManager.default.removeItem(at: out) }
        }

        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let dstCapacity = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        var stream = compression_stream(dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            dummy.deallocate(); dst.deallocate()
            throw ProviderError.invalidResponse
        }
        defer {
            compression_stream_destroy(&stream)
            dummy.deallocate(); dst.deallocate()
        }

        do {
            try input.seek(toOffset: UInt64(header))
            var finished = false
            var written = 0
            while !finished {
                let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                let isLast = chunk.isEmpty
                let flags = isLast ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                try chunk.withUnsafeBytes { raw in
                    stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dummy)
                    stream.src_size = chunk.count
                    repeat {
                        stream.dst_ptr = dst
                        stream.dst_size = dstCapacity
                        let status = compression_stream_process(&stream, flags)
                        guard status != COMPRESSION_STATUS_ERROR else { throw ProviderError.invalidResponse }
                        let produced = dstCapacity - stream.dst_size
                        if produced > 0 {
                            guard fits(total: written, adding: produced, limit: maxOutputBytes) else {
                                throw ProviderError.invalidResponse
                            }
                            written += produced
                            try output.write(contentsOf: Data(bytes: dst, count: produced))
                        }
                        if status == COMPRESSION_STATUS_END { finished = true }
                    } while !finished && (stream.src_size > 0 || stream.dst_size == 0)
                }
                // Strömmen tog slut utan att deflate-slutmarkören sågs: trasig eller avkapad fil.
                if isLast && !finished { throw ProviderError.invalidResponse }
            }
        } catch {
            throw ProviderError.invalidResponse
        }
        succeeded = true
        return out
    }
    #endif
}
