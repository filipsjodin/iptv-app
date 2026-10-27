import Foundation
import Providers

/// Fel från OMDb. API-nyckeln är alltid bortredigerad ur texten.
public enum OMDbError: Error, Equatable, CustomStringConvertible {
    case unauthorized
    case notFound
    case rateLimited
    case http(Int)
    case invalidResponse
    /// Nätverksfel; `reason` är redigerad (nyckeln ersatt med `REDACTED`).
    case unavailable(reason: String)

    public var description: String {
        switch self {
        case .unauthorized: "OMDb nekade API-nyckeln"
        case .notFound: "Titeln finns inte hos OMDb"
        case .rateLimited: "OMDb:s anropsgräns är nådd"
        case let .http(code): "OMDb svarade med HTTP \(code)"
        case .invalidResponse: "Ogiltigt svar från OMDb"
        case let .unavailable(reason): "OMDb kan inte nås: \(reason)"
        }
    }
}

/// Klient för OMDb-betyg. OMDb kräver nyckeln som query-parameter; den loggas aldrig och redigeras ur fel.
public struct OMDbClient: Sendable {
    static let baseURL = "https://www.omdbapi.com/"

    private let apiKey: String
    private let http: HTTPClient

    public init(apiKey: String, http: HTTPClient) {
        self.apiKey = apiKey
        self.http = http
    }

    public func ratings(imdbID: String) async throws -> ExternalRatings {
        guard var components = URLComponents(string: Self.baseURL) else { throw OMDbError.invalidResponse }
        components.queryItems = [URLQueryItem(name: "i", value: imdbID), URLQueryItem(name: "apikey", value: apiKey)]
        guard let url = components.url else { throw OMDbError.invalidResponse }

        let data: Data, status: Int
        do {
            (data, status, _) = try await http.get(url, headers: ["Accept": "application/json"])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OMDbError.unavailable(reason: redact(String(describing: error)))
        }

        switch status {
        case 200..<300: break
        case 401: throw OMDbError.unauthorized
        case 404: throw OMDbError.notFound
        case 429: throw OMDbError.rateLimited
        default: throw OMDbError.http(status)
        }
        guard let dto = try? JSONDecoder().decode(OMDbDTO.self, from: data) else { throw OMDbError.invalidResponse }
        if dto.response?.lowercased() == "false" {
            let message = (dto.error ?? "").lowercased()
            if message.contains("api key") { throw OMDbError.unauthorized }
            if message.contains("limit") { throw OMDbError.rateLimited }
            throw OMDbError.notFound
        }
        return ExternalRatings(imdb: Self.parseIMDb(dto.imdbRating), rottenTomatoes: Self.parseRottenTomatoes(dto.ratings))
    }

    /// "7.8" ger 7.8, "N/A" eller tomt ger nil.
    static func parseIMDb(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite, (0...10).contains(value) else { return nil }
        return value
    }

    /// Källan "Rotten Tomatoes" med värdet "93%" ger 93.
    static func parseRottenTomatoes(_ ratings: [OMDbDTO.Rating]?) -> Int? {
        guard let value = ratings?.first(where: { $0.source == "Rotten Tomatoes" })?.value else { return nil }
        let digits = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let percent = Int(digits), (0...100).contains(percent) else { return nil }
        return percent
    }

    /// Ersätter nyckeln (rå och procentkodad) med `REDACTED`.
    private func redact(_ text: String) -> String {
        guard !apiKey.isEmpty else { return text }
        var out = text
        var variants = [apiKey]
        if let encoded = apiKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { variants.append(encoded) }
        if let encoded = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { variants.append(encoded) }
        for v in Set(variants).sorted(by: { $0.count > $1.count }) where !v.isEmpty {
            out = out.replacingOccurrences(of: v, with: Redactor.placeholder)
        }
        return out
    }
}

extension OMDbClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "OMDbClient(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

struct OMDbDTO: Decodable {
    let response: String?
    let error: String?
    let imdbRating: String?
    let ratings: [Rating]?

    enum CodingKeys: String, CodingKey {
        case response = "Response"
        case error = "Error"
        case imdbRating
        case ratings = "Ratings"
    }

    struct Rating: Decodable {
        let source: String?
        let value: String?
        enum CodingKeys: String, CodingKey {
            case source = "Source"
            case value = "Value"
        }
    }
}
