import Foundation
import Core
import Providers

/// Fel från TMDB. Innehåller aldrig URL:er eller token.
public enum TMDBError: Error, Equatable, CustomStringConvertible {
    case unauthorized
    case rateLimited(retryAfter: Double?)
    case notFound
    case http(Int)
    case invalidResponse
    case unavailable

    public var description: String {
        switch self {
        case .unauthorized: "TMDB nekade åtkomst"
        case let .rateLimited(retryAfter): "TMDB begränsar anropen" + (retryAfter.map { " (försök igen om \($0) s)" } ?? "")
        case .notFound: "Titeln finns inte hos TMDB"
        case let .http(code): "TMDB svarade med HTTP \(code)"
        case .invalidResponse: "Ogiltigt svar från TMDB"
        case .unavailable: "TMDB kan inte nås"
        }
    }
}

/// Klient för TMDB v3. Token skickas enbart som `Authorization: Bearer`-header, aldrig i URL:en.
public struct TMDBClient: Sendable {
    static let baseURL = "https://api.themoviedb.org/3"

    private let token: String
    private let http: HTTPClient
    public let language: String
    public let fallbackLanguage: String

    public init(token: String, http: HTTPClient, language: String = "sv-SE", fallbackLanguage: String = "en-US") {
        self.token = token
        self.http = http
        self.language = language
        self.fallbackLanguage = fallbackLanguage
    }

    // MARK: - API

    public func search(_ query: String, year: Int?, kind: ContentKind) async throws -> [TMDBSearchResult] {
        guard let segment = Self.segment(for: kind) else { return [] }
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false"),
                     URLQueryItem(name: "language", value: language), URLQueryItem(name: "page", value: "1")]
        if let year {
            items.append(URLQueryItem(name: kind == .series ? "first_air_date_year" : "year", value: String(year)))
        }
        let page: TMDBPage<TMDBSearchItemDTO> = try await fetch("/search/\(segment)", items)
        return (page.results ?? []).compactMap { $0.result(kind: kind) }
    }

    public func details(id: Int, kind: ContentKind) async throws -> TitleMetadata {
        guard let segment = Self.segment(for: kind) else { throw TMDBError.notFound }
        let ratings = kind == .series ? "content_ratings" : "release_dates"
        let append = "credits,keywords,recommendations,similar,images,\(ratings),external_ids"
        let dto: TMDBDetailsDTO = try await fetch("/\(segment)/\(id)", [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "append_to_response", value: append),
            URLQueryItem(name: "include_image_language", value: "sv,en,null"),
        ])
        var metadata = try dto.metadata(kind: kind, language: language)
        if metadata.overview == nil, fallbackLanguage != language {
            // Bara översikten hämtas på reservspråket. Misslyckas anropet behålls övrig metadata utan översikt.
            do {
                let fallback: TMDBOverviewDTO = try await fetch("/\(segment)/\(id)", [URLQueryItem(name: "language", value: fallbackLanguage)])
                metadata.overview = nonEmpty(fallback.overview)
            } catch is CancellationError {
                throw CancellationError()
            } catch TMDBError.rateLimited(let retryAfter) {
                // Anropsgränsen gäller hela klienten: anroparen måste få veta det för att kunna backa.
                throw TMDBError.rateLimited(retryAfter: retryAfter)
            } catch {}
        }
        return metadata
    }

    /// Avsnitten i en säsong (titel, beskrivning, speltid, stillbild) per avsnittsnummer. Titlar och beskrivningar
    /// som saknas på klientens språk fylls på från reservspråket; misslyckas det anropet behålls det som finns.
    public func seasonEpisodes(seriesID: Int, season: Int) async throws -> [Int: TMDBEpisodeInfo] {
        let path = "/tv/\(seriesID)/season/\(season)"
        let primary: TMDBSeasonDTO = try await fetch(path, [URLQueryItem(name: "language", value: language)])
        var infos = primary.infos()
        guard fallbackLanguage != language,
              infos.values.contains(where: { $0.name == nil || $0.overview == nil }) else { return infos }
        do {
            let fallback: TMDBSeasonDTO = try await fetch(path, [URLQueryItem(name: "language", value: fallbackLanguage)])
            for (number, extra) in fallback.infos() {
                guard var info = infos[number] else { continue }
                info.name = info.name ?? extra.name
                info.overview = info.overview ?? extra.overview
                infos[number] = info
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch TMDBError.rateLimited(let retryAfter) {
            throw TMDBError.rateLimited(retryAfter: retryAfter)
        } catch {}
        return infos
    }

    public func trending(kind: ContentKind, window: TrendingWindow = .week) async throws -> [Int] {
        guard let segment = Self.segment(for: kind) else { return [] }
        let page: TMDBPage<TMDBIDOnly> = try await fetch("/trending/\(segment)/\(window.rawValue)", [
            URLQueryItem(name: "language", value: language),
        ])
        return page.results?.map(\.id) ?? []
    }

    public func popular(kind: ContentKind, region: String = "SE") async throws -> [Int] {
        guard let segment = Self.segment(for: kind) else { return [] }
        let page: TMDBPage<TMDBIDOnly> = try await fetch("/\(segment)/popular", [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "region", value: region),
            URLQueryItem(name: "page", value: "1"),
        ])
        return page.results?.map(\.id) ?? []
    }

    // MARK: - Transport

    private static func segment(for kind: ContentKind) -> String? {
        switch kind {
        case .movie: "movie"
        case .series: "tv"
        case .live: nil
        }
    }

    private func fetch<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        guard var components = URLComponents(string: Self.baseURL + path) else { throw TMDBError.invalidResponse }
        // `+ & = #` procentkodas uttryckligen: `URLComponents.queryItems` lämnar `+`, `&` och `=` okodade, och
        // servrar tolkar `+` som blanksteg och `&`/`=` som parameterskiljare.
        components.percentEncodedQueryItems = query.map {
            URLQueryItem(name: Self.encodeQuery($0.name), value: $0.value.map(Self.encodeQuery))
        }
        guard let url = components.url else { throw TMDBError.invalidResponse }
        let headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]

        let data: Data, status: Int, responseHeaders: [String: String]
        do {
            (data, status, responseHeaders) = try await http.get(url, headers: headers)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Underliggande fel (t.ex. URLError med URL) vidarebefordras aldrig.
            throw TMDBError.unavailable
        }

        switch status {
        case 200..<300: break
        case 401: throw TMDBError.unauthorized
        case 404: throw TMDBError.notFound
        case 429: throw TMDBError.rateLimited(retryAfter: Self.retryAfter(responseHeaders))
        default: throw TMDBError.http(status)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TMDBError.invalidResponse
        }
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=#")
        return set
    }()

    static func encodeQuery(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
    }

    /// `Retry-After` i sekunder (skiftlägesokänsligt headernamn); HTTP-datumformen stöds inte.
    static func retryAfter(_ headers: [String: String]) -> Double? {
        guard let raw = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value,
              let seconds = Double(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0, seconds.isFinite else { return nil }
        return seconds
    }
}

extension TMDBClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "TMDBClient(language: \(language))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["language": language], displayStyle: .struct) }
}
