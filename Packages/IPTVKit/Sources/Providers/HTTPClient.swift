import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP-abstraktion så att klienter kan testas utan nätverk.
public protocol HTTPClient: Sendable {
    /// Returnerar body och statuskod.
    func get(_ url: URL) async throws -> (Data, Int)
    /// Som `get(_:)` men med request-headers; returnerar även svarets headers (nycklar som de mottogs).
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int, [String: String])
    /// Hämtar till en temporär fil (för stora svar som EPG) och returnerar filen och statuskoden.
    /// Anroparen äger filen och tar bort den.
    func download(_ url: URL) async throws -> (file: URL, status: Int)
}

extension HTTPClient {
    /// Standard: ignorerar request-headers och returnerar inga svarsheaders.
    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int, [String: String]) {
        let (data, status) = try await get(url)
        return (data, status, [:])
    }

    /// Standard: hämtar via `get(_:)` och skriver bodyn till en temporärfil.
    public func download(_ url: URL) async throws -> (file: URL, status: Int) {
        let (data, status) = try await get(url)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)")
        do { try data.write(to: file) } catch { throw ProviderError.unreachable }
        return (file, status)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    public static let defaultUserAgent = "IPTVApp/1.0"

    private let session: URLSession
    private let userAgent: String
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 30, resourceTimeout: TimeInterval = 600, userAgent: String = URLSessionHTTPClient.defaultUserAgent) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = resourceTimeout
        self.session = URLSession(configuration: config)
        self.userAgent = userAgent
        self.timeout = timeout
    }

    public func get(_ url: URL) async throws -> (Data, Int) {
        let (data, status, _) = try await get(url, headers: [:])
        return (data, status)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int, [String: String]) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        var responseHeaders: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            guard let name = k as? String else { continue }
            responseHeaders[name] = (v as? String) ?? String(describing: v)
        }
        return (data, http.statusCode, responseHeaders)
    }

    #if !canImport(FoundationNetworking)
    public func download(_ url: URL) async throws -> (file: URL, status: Int) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tmp)
            throw ProviderError.invalidResponse
        }
        // Flytta till egen sökväg så att filen överlever sessionens städning.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)")
        do { try FileManager.default.moveItem(at: tmp, to: file) } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ProviderError.unreachable
        }
        return (file, http.statusCode)
    }
    #endif
}
