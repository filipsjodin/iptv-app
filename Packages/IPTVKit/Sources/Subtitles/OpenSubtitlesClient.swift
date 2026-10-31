import Foundation
import Providers
import PlaybackCore

public struct OpenSubtitlesQuery: Sendable, Equatable {
    public var tmdbID: Int?
    public var imdbID: String?
    public var season: Int?
    public var episode: Int?
    public var title: String?
    public var year: Int?
    public var languages: [String]

    public init(tmdbID: Int? = nil, imdbID: String? = nil, season: Int? = nil, episode: Int? = nil,
                title: String? = nil, year: Int? = nil, languages: [String] = []) {
        self.tmdbID = tmdbID; self.imdbID = imdbID; self.season = season; self.episode = episode
        self.title = title; self.year = year; self.languages = languages
    }
}

public struct OpenSubtitlesResult: Sendable, Hashable, Identifiable {
    /// `file_id` hos OpenSubtitles.
    public var id: Int
    public var language: String
    public var release: String
    public var fileName: String
    public var rating: Double
    public var downloadCount: Int
    public var hearingImpaired: Bool
    public var aiTranslated: Bool

    public init(id: Int, language: String, release: String, fileName: String, rating: Double,
                downloadCount: Int, hearingImpaired: Bool, aiTranslated: Bool) {
        self.id = id; self.language = language; self.release = release; self.fileName = fileName
        self.rating = rating; self.downloadCount = downloadCount
        self.hearingImpaired = hearingImpaired; self.aiTranslated = aiTranslated
    }
}

public struct OpenSubtitlesQuota: Sendable, Equatable {
    public var remaining: Int?
    public var allowed: Int?
    public var resetAt: Date?

    public init(remaining: Int? = nil, allowed: Int? = nil, resetAt: Date? = nil) {
        self.remaining = remaining; self.allowed = allowed; self.resetAt = resetAt
    }
}

/// Fasta fel utan text från servern, URL:er eller inloggning.
public enum OpenSubtitlesError: Error, Sendable, Equatable {
    case noAPIKey
    case notLoggedIn
    case invalidCredentials
    case quotaExhausted(resetAt: Date?)
    case rateLimited(retryAfter: TimeInterval?)
    case network
    case badResponse
}

/// Klient för OpenSubtitles REST API v1. Nyckel och token hålls bara i minnet i privata fält.
public final class OpenSubtitlesClient: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private static let defaultHost = "api.opensubtitles.com"
    private static let cacheTTL: TimeInterval = 600

    private let apiKey: String?
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var token: String?
    private var host = OpenSubtitlesClient.defaultHost
    private var cache: [String: (at: Date, results: [OpenSubtitlesResult])] = [:]

    public init(apiKey: String?, http: HTTPClient, now: @Sendable @escaping () -> Date = Date.init) {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.http = http
        self.now = now
    }

    public var description: String { "OpenSubtitlesClient(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }

    public var isLoggedIn: Bool { lock.withLock { token != nil } }

    public func logout() {
        lock.withLock { token = nil; host = Self.defaultHost }
    }

    // MARK: - Publikt API

    public func login(username: String, password: String) async throws -> OpenSubtitlesQuota {
        let key = try requireKey()
        let body = try encode(["username": username, "password": password])
        let (data, status, headers) = try await send(post: "login", key: key, token: nil, body: body, host: Self.defaultHost)
        switch status {
        case 200..<300: break
        case 400, 401, 403, 422: throw OpenSubtitlesError.invalidCredentials
        default: throw map(status: status, data: data, headers: headers)
        }
        let dto = try decode(LoginDTO.self, data)
        guard let newToken = dto.token, !newToken.isEmpty else { throw OpenSubtitlesError.badResponse }
        let newHost = Self.validHost(dto.baseURL) ?? Self.defaultHost
        lock.withLock { token = newToken; host = newHost }
        return OpenSubtitlesQuota(remaining: dto.user?.remainingDownloads, allowed: dto.user?.allowedDownloads, resetAt: nil)
    }

    public func search(_ query: OpenSubtitlesQuery) async throws -> [OpenSubtitlesResult] {
        let key = try requireKey()
        let items = Self.queryItems(for: query)
        guard !items.isEmpty else { throw OpenSubtitlesError.badResponse }
        let cacheKey = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        let t = now()
        if let hit = lock.withLock({ cache[cacheKey] }), t.timeIntervalSince(hit.at) < Self.cacheTTL {
            return hit.results
        }
        let (data, status, headers) = try await send(get: "subtitles", items: items, key: key, token: nil, host: currentHost())
        switch status {
        case 200..<300: break
        case 401: throw OpenSubtitlesError.noAPIKey
        default: throw map(status: status, data: data, headers: headers)
        }
        let dto = try decode(SearchDTO.self, data)
        let results = (dto.data ?? []).compactMap { Self.result(from: $0.attributes) }
        lock.withLock { cache[cacheKey] = (t, results) }
        return results
    }

    public func download(fileID: Int) async throws -> (data: Data, quota: OpenSubtitlesQuota) {
        let key = try requireKey()
        let (tok, host) = try session()
        let body = try encode(["file_id": fileID])
        let (data, status, headers) = try await send(post: "download", key: key, token: tok, body: body, host: host)
        switch status {
        case 200..<300: break
        case 401:
            logout()
            throw OpenSubtitlesError.notLoggedIn
        default: throw map(status: status, data: data, headers: headers)
        }
        let dto = try decode(DownloadDTO.self, data)
        guard let linkText = dto.link, let link = URL(string: linkText), link.scheme?.lowercased() == "https", link.host != nil else {
            throw OpenSubtitlesError.badResponse
        }
        let file: (Data, Int)
        do { file = try await http.get(link) } catch is CancellationError { throw CancellationError() } catch { throw OpenSubtitlesError.network }
        guard (200..<300).contains(file.1), !file.0.isEmpty else { throw OpenSubtitlesError.badResponse }
        let quota = OpenSubtitlesQuota(remaining: dto.remaining, allowed: nil, resetAt: Self.parseDate(dto.resetTimeUTC))
        return (file.0, quota)
    }

    public func quota() async throws -> OpenSubtitlesQuota {
        let key = try requireKey()
        let (tok, host) = try session()
        let (data, status, headers) = try await send(get: "infos/user", items: [], key: key, token: tok, host: host)
        switch status {
        case 200..<300: break
        case 401:
            logout()
            throw OpenSubtitlesError.notLoggedIn
        default: throw map(status: status, data: data, headers: headers)
        }
        let dto = try decode(UserInfoDTO.self, data)
        return OpenSubtitlesQuota(remaining: dto.data?.remainingDownloads, allowed: dto.data?.allowedDownloads, resetAt: nil)
    }

    // MARK: - Hjälpare

    private func requireKey() throws -> String {
        guard let apiKey else { throw OpenSubtitlesError.noAPIKey }
        return apiKey
    }

    private func currentHost() -> String { lock.withLock { host } }

    private func session() throws -> (token: String, host: String) {
        try lock.withLock {
            guard let token else { throw OpenSubtitlesError.notLoggedIn }
            return (token, host)
        }
    }

    private func headers(key: String, token: String?) -> [String: String] {
        var h = ["Api-Key": key, "User-Agent": "IPTVApp v1.0", "Content-Type": "application/json", "Accept": "application/json"]
        if let token { h["Authorization"] = "Bearer \(token)" }
        return h
    }

    private func url(host: String, path: String, items: [URLQueryItem]) throws -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/api/v1/\(path)"
        if !items.isEmpty { c.queryItems = items }
        guard let u = c.url else { throw OpenSubtitlesError.badResponse }
        return u
    }

    private func send(get path: String, items: [URLQueryItem], key: String, token: String?, host: String) async throws -> (Data, Int, [String: String]) {
        let u = try url(host: host, path: path, items: items)
        do { return try await http.get(u, headers: headers(key: key, token: token)) }
        catch is CancellationError { throw CancellationError() }
        catch { throw OpenSubtitlesError.network }
    }

    private func send(post path: String, key: String, token: String?, body: Data, host: String) async throws -> (Data, Int, [String: String]) {
        let u = try url(host: host, path: path, items: [])
        do { return try await http.post(u, headers: headers(key: key, token: token), body: body) }
        catch is CancellationError { throw CancellationError() }
        catch { throw OpenSubtitlesError.network }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) } catch { throw OpenSubtitlesError.badResponse }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw OpenSubtitlesError.badResponse }
    }

    private func map(status: Int, data: Data, headers: [String: String]) -> OpenSubtitlesError {
        switch status {
        case 406:
            let reset = (try? JSONDecoder().decode(DownloadDTO.self, from: data)).flatMap { Self.parseDate($0.resetTimeUTC) }
            return .quotaExhausted(resetAt: reset)
        case 429:
            let value = headers.first { $0.key.lowercased() == "retry-after" }?.value
            let seconds = value.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
            return .rateLimited(retryAfter: seconds)
        default:
            return .badResponse
        }
    }

    /// Godtar bara OpenSubtitles egna värdar så att token aldrig skickas till en främmande server.
    private static func validHost(_ raw: String?) -> String? {
        guard var h = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("https://") { h.removeFirst("https://".count) }
        if h.hasSuffix("/") { h.removeLast() }
        let allowed = h.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        guard allowed, h == "opensubtitles.com" || h.hasSuffix(".opensubtitles.com") else { return nil }
        return h
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    /// OpenSubtitles kräver gemener och alfabetisk ordning på parametrarna.
    private static func queryItems(for q: OpenSubtitlesQuery) -> [URLQueryItem] {
        var m: [String: String] = [:]
        let isEpisode = q.season != nil || q.episode != nil
        if let id = q.tmdbID { m[isEpisode ? "parent_tmdb_id" : "tmdb_id"] = String(id) }
        if let imdb = q.imdbID?.trimmingCharacters(in: .whitespaces), !imdb.isEmpty {
            let digits = imdb.lowercased().hasPrefix("tt") ? String(imdb.dropFirst(2)) : imdb
            m[isEpisode ? "parent_imdb_id" : "imdb_id"] = digits
        }
        if let s = q.season { m["season_number"] = String(s) }
        if let e = q.episode { m["episode_number"] = String(e) }
        if m.isEmpty, let t = q.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            m["query"] = t
            if let y = q.year { m["year"] = String(y) }
        }
        guard !m.isEmpty else { return [] }
        let langs = q.languages.compactMap { LanguageCode.normalize($0) }
        if !langs.isEmpty { m["languages"] = langs.joined(separator: ",") }
        return m.keys.sorted().map { URLQueryItem(name: $0, value: m[$0]) }
    }

    private static func result(from a: SearchDTO.Attributes?) -> OpenSubtitlesResult? {
        guard let a, let file = a.files?.first, let fileID = file.fileID else { return nil }
        let lang = LanguageCode.normalize(a.language) ?? a.language?.lowercased() ?? ""
        return OpenSubtitlesResult(
            id: fileID, language: lang, release: a.release ?? "", fileName: file.fileName ?? "",
            rating: a.ratings ?? 0, downloadCount: a.downloadCount ?? 0,
            hearingImpaired: a.hearingImpaired ?? false,
            aiTranslated: (a.aiTranslated ?? false) || (a.machineTranslated ?? false))
    }
}

// MARK: - DTO:er (API:t är inkonsekvent, allt är valfritt)

private struct LoginDTO: Decodable {
    struct User: Decodable {
        var allowedDownloads: Int?
        var remainingDownloads: Int?
        enum CodingKeys: String, CodingKey { case allowedDownloads = "allowed_downloads", remainingDownloads = "remaining_downloads" }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            allowedDownloads = try c.decodeIfPresent(Int.self, forKey: .allowedDownloads)
            remainingDownloads = try c.decodeIfPresent(Int.self, forKey: .remainingDownloads)
        }
    }
    var token: String?
    var baseURL: String?
    var user: User?
    enum CodingKeys: String, CodingKey { case token, user, baseURL = "base_url" }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        user = try? c.decodeIfPresent(User.self, forKey: .user)
    }
}

private struct UserInfoDTO: Decodable {
    var data: LoginDTO.User?
    enum CodingKeys: String, CodingKey { case data }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        data = try? c.decodeIfPresent(LoginDTO.User.self, forKey: .data)
    }
}

private struct DownloadDTO: Decodable {
    var link: String?
    var remaining: Int?
    var resetTimeUTC: String?
    enum CodingKeys: String, CodingKey { case link, remaining, resetTimeUTC = "reset_time_utc" }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        remaining = try c.decodeIfPresent(Int.self, forKey: .remaining)
        resetTimeUTC = try c.decodeIfPresent(String.self, forKey: .resetTimeUTC)
    }
}

private struct SearchDTO: Decodable {
    struct File: Decodable {
        var fileID: Int?
        var fileName: String?
        enum CodingKeys: String, CodingKey { case fileID = "file_id", fileName = "file_name" }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            fileID = try c.decodeIfPresent(Int.self, forKey: .fileID)
            fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        }
    }
    struct Attributes: Decodable {
        var language: String?
        var release: String?
        var ratings: Double?
        var downloadCount: Int?
        var hearingImpaired: Bool?
        var aiTranslated: Bool?
        var machineTranslated: Bool?
        var files: [File]?
        enum CodingKeys: String, CodingKey {
            case language, release, ratings, files
            case downloadCount = "download_count", hearingImpaired = "hearing_impaired"
            case aiTranslated = "ai_translated", machineTranslated = "machine_translated"
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            language = try c.decodeIfPresent(String.self, forKey: .language)
            release = try c.decodeIfPresent(String.self, forKey: .release)
            ratings = try c.decodeIfPresent(Double.self, forKey: .ratings)
            downloadCount = try c.decodeIfPresent(Int.self, forKey: .downloadCount)
            hearingImpaired = try c.decodeIfPresent(Bool.self, forKey: .hearingImpaired)
            aiTranslated = try c.decodeIfPresent(Bool.self, forKey: .aiTranslated)
            machineTranslated = try c.decodeIfPresent(Bool.self, forKey: .machineTranslated)
            files = try c.decodeIfPresent([File].self, forKey: .files)
        }
    }
    struct Item: Decodable { var attributes: Attributes? }
    var data: [Item]?
}
