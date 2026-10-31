import Testing
import Foundation
@testable import Providers

private func tempFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gz-test-\(UUID().uuidString)")
    try data.write(to: url)
    return url
}

@Suite struct GzipFileTests {
    private let base: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]

    @Test func headerLengthPlain() {
        #expect(GzipFile.headerLength(Data(base)) == 10)
    }

    @Test func headerLengthWithFName() {
        var b = base; b[3] = 0x08
        b += Array("guide.xml".utf8) + [0]
        b += [0xAA, 0xBB]   // början av deflate-data
        #expect(GzipFile.headerLength(Data(b)) == 10 + 10)
    }

    @Test func headerLengthWithFExtra() {
        var b = base; b[3] = 0x04
        b += [3, 0, 1, 2, 3]
        b += [0xAA]
        #expect(GzipFile.headerLength(Data(b)) == 15)
    }

    @Test func headerLengthWithFExtraFNameFCommentFHCRC() {
        var b = base; b[3] = 0x04 | 0x08 | 0x10 | 0x02
        b += [2, 0, 9, 9]
        b += Array("n".utf8) + [0]
        b += Array("cc".utf8) + [0]
        b += [0, 0]
        b += [0xAA]
        #expect(GzipFile.headerLength(Data(b)) == 10 + 4 + 2 + 3 + 2)
    }

    @Test func headerLengthNilForTruncatedOptionalFields() {
        var b = base; b[3] = 0x08
        b += Array("abc".utf8)   // ingen nollterminator
        #expect(GzipFile.headerLength(Data(b)) == nil)
    }

    @Test func headerLengthNilForPlainXML() {
        #expect(GzipFile.headerLength(Data("<?xml version=\"1.0\"?><tv/>".utf8)) == nil)
    }

    @Test func headerLengthNilForEmptyAndShort() {
        #expect(GzipFile.headerLength(Data()) == nil)
        #expect(GzipFile.headerLength(Data([0x1F, 0x8B, 0x08])) == nil)
    }

    @Test func inflateOfPlainFileReturnsSameURL() throws {
        let src = try tempFile(Data("<tv></tv>".utf8))
        defer { try? FileManager.default.removeItem(at: src) }
        #expect(try GzipFile.inflate(src) == src)
    }

    #if canImport(Compression)
    // Apple-bara: verifieras i CI.
    @Test func inflateRoundTrip() throws {
        // gzip av "hello hello hello\n" (deflate-ström, fast Huffman) skapad med gzip -n.
        let gz: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03,
                           0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0xC8, 0x40, 0x90, 0x5C, 0x00,
                           0x3B, 0x7C, 0x8A, 0xDF, 0x12, 0x00, 0x00, 0x00]
        let src = try tempFile(Data(gz))
        defer { try? FileManager.default.removeItem(at: src) }
        let out = try GzipFile.inflate(src)
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello hello hello\n")
    }

    @Test func corruptGzipThrows() throws {
        var b = base
        b += [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let src = try tempFile(Data(b))
        defer { try? FileManager.default.removeItem(at: src) }
        #expect(throws: ProviderError.self) { try GzipFile.inflate(src) }
    }
    #else
    @Test func gzipThrowsUnsupportedOffApple() throws {
        let src = try tempFile(Data(base + [0, 0, 0, 0]))
        defer { try? FileManager.default.removeItem(at: src) }
        #expect(throws: ProviderError.invalidResponse) { try GzipFile.inflate(src) }
    }
    #endif
}
