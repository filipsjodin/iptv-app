import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP-abstraktion så att klienter kan testas utan nätverk.
public protocol HTTPClient: Sendable {
    /// Returnerar body och statuskod.
    func get(_ url: URL) async throws -> (Data, Int)
}

public struct URLSessionHTTPClient: HTTPClient {
    public static let defaultUserAgent = "IPTVApp/1.0"

    private let session: URLSession
    private let userAgent: String
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 30, userAgent: String = URLSessionHTTPClient.defaultUserAgent) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 4
        self.session = URLSession(configuration: config)
        self.userAgent = userAgent
        self.timeout = timeout
    }

    public func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        return (data, http.statusCode)
    }
}
