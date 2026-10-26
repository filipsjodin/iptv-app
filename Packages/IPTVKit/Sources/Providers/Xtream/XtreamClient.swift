import Foundation
import Core
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct XtreamAccount: Sendable, Equatable {
    public var status: String
    public var expiresAt: Date?
    public var maxConnections: Int
    public var activeConnections: Int
    public var isTrial: Bool
    public var allowedOutputFormats: [String]

    public init(status: String, expiresAt: Date?, maxConnections: Int, activeConnections: Int,
                isTrial: Bool, allowedOutputFormats: [String]) {
        self.status = status
        self.expiresAt = expiresAt
        self.maxConnections = maxConnections
        self.activeConnections = activeConnections
        self.isTrial = isTrial
        self.allowedOutputFormats = allowedOutputFormats
    }
}

public struct XtreamClient: Sendable {
    private let server: URL
    private let username: String
    private let password: String
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    public init(server: URL, username: String, password: String, http: HTTPClient) {
        self.init(server: server, username: username, password: password, http: http, now: { Date() })
    }

    init(server: URL, username: String, password: String, http: HTTPClient, now: @escaping @Sendable () -> Date) {
        self.server = server
        self.username = username
        self.password = password
        self.http = http
        self.now = now
    }

    public func account() async throws -> XtreamAccount {
        let data = try await fetch(action: nil)
        guard let info = (try? JSONDecoder().decode(XtreamUserInfoResponse.self, from: data))?.userInfo else {
            throw ProviderError.invalidResponse
        }
        if info.auth == 0 { throw ProviderError.unauthorized }
        let status = info.status ?? ""
        let expiresAt = XtreamMapper.date(info.expDate)
        switch status.lowercased() {
        case "disabled", "banned": throw ProviderError.accountDisabled
        case "expired": throw ProviderError.accountExpired(expiresAt ?? now())
        default: break
        }
        if let expiresAt, expiresAt < now() { throw ProviderError.accountExpired(expiresAt) }
        if info.auth == nil && status.lowercased() != "active" { throw ProviderError.unauthorized }
        return XtreamAccount(status: status, expiresAt: expiresAt, maxConnections: info.maxConnections ?? 1,
                             activeConnections: info.activeCons ?? 0, isTrial: (info.isTrial ?? 0) != 0,
                             allowedOutputFormats: info.allowedOutputFormats.values)
    }

    /// Skickas `account` in (t.ex. från ett nyss gjort `account()`-anrop) hoppas ny autentisering över.
    public func catalog(account prefetched: XtreamAccount? = nil) async throws -> ProviderCatalog {
        let account: XtreamAccount
        if let prefetched { account = prefetched } else { account = try await self.account() }
        async let vodCats: [XtreamCategoryDTO] = list("get_vod_categories", tolerate404: true)
        async let seriesCats: [XtreamCategoryDTO] = list("get_series_categories", tolerate404: true)
        async let liveCats: [XtreamCategoryDTO] = list("get_live_categories", tolerate404: true)
        async let vod: [XtreamVodDTO] = list("get_vod_streams", tolerate404: false)
        async let series: [XtreamSeriesDTO] = list("get_series", tolerate404: false)
        async let live: [XtreamLiveDTO] = list("get_live_streams", tolerate404: false)

        let liveContainer = account.allowedOutputFormats.contains { $0.lowercased() == "m3u8" } ? "m3u8" : "ts"
        let (vc, sc, lc, v, s, l) = try await (vodCats, seriesCats, liveCats, vod, series, live)
        return ProviderCatalog(
            categories: XtreamMapper.categories(vc, kind: .movie)
                + XtreamMapper.categories(sc, kind: .series)
                + XtreamMapper.categories(lc, kind: .live),
            movies: XtreamMapper.movies(v),
            series: XtreamMapper.series(s),
            episodes: [],
            live: XtreamMapper.live(l, container: liveContainer),
            episodesComplete: false)
    }

    public func episodes(seriesID: String) async throws -> [Episode] {
        let data = try await fetch(action: "get_series_info", extra: [("series_id", seriesID)])
        guard let info = try? JSONDecoder().decode(XtreamSeriesInfoResponse.self, from: data) else {
            throw ProviderError.invalidResponse
        }
        return XtreamMapper.episodes(info, seriesID: seriesID)
    }

    // MARK: - Internt

    /// Tom lista ENDAST för blank body, `null`, `[]` och `{}` (och 404 för kategorilistor). Allt annat som inte går
    /// att avkoda kastas som `.invalidResponse`, så att en felsida aldrig tolkas som ett tomt bibliotek.
    private func list<T: XtreamRow>(_ action: String, tolerate404: Bool) async throws -> [T] {
        let data: Data
        do { data = try await fetch(action: action) }
        catch ProviderError.http(404) where tolerate404 { return [] }
        return try Self.decodeRows(data)
    }

    static func decodeRows<T: XtreamRow>(_ data: Data) throws -> [T] {
        let decoder = JSONDecoder()
        if isEmptyPayload(data) { return [] }
        let rows: [T?]
        if let arr = try? decoder.decode([LenientRow<T>].self, from: data) {
            rows = arr.map { $0.value }
        } else if let obj = try? decoder.decode([String: LenientRow<T>].self, from: data) {
            rows = obj.sorted { Self.keyOrder($0.key, $1.key) }.map { $0.value.value }
        } else {
            throw ProviderError.invalidResponse
        }
        let valid = rows.compactMap { $0 }.filter { $0.isValidRow }
        if !rows.isEmpty && valid.isEmpty { throw ProviderError.invalidResponse }
        return valid
    }

    /// Blank body, `null`, `[]` eller `{}` (blanktecken tillåtet utanför och inuti), avgjort på bytenivå utan kopia.
    private static func isEmptyPayload(_ data: Data) -> Bool {
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
        return data.withUnsafeBytes { raw -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            var lo = 0, hi = b.count
            while lo < hi, isSpace(b[lo]) { lo += 1 }
            while hi > lo, isSpace(b[hi - 1]) { hi -= 1 }
            if lo == hi { return true }
            let first = b[lo]
            if first == UInt8(ascii: "n") {   // "null"
                return hi - lo == 4 && b[lo + 1] == UInt8(ascii: "u") && b[lo + 2] == UInt8(ascii: "l")
                    && b[lo + 3] == UInt8(ascii: "l")
            }
            let close: UInt8
            switch first {
            case UInt8(ascii: "["): close = UInt8(ascii: "]")
            case UInt8(ascii: "{"): close = UInt8(ascii: "}")
            default: return false
            }
            guard hi - lo >= 2, b[hi - 1] == close else { return false }
            var i = lo + 1
            while i < hi - 1 { if !isSpace(b[i]) { return false }; i += 1 }
            return true
        }
    }

    /// Numeriska nycklar först i numerisk ordning, därefter övriga alfabetiskt.
    private static func keyOrder(_ a: String, _ b: String) -> Bool {
        switch (Int(a), Int(b)) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a < b
        }
    }

    private func fetch(action: String?, extra: [(String, String)] = []) async throws -> Data {
        let url = try makeURL(action: action, extra: extra)
        let data: Data
        let status: Int
        do {
            (data, status) = try await http.get(url)
        } catch let e as ProviderError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // URLError m.fl. kan bära URL:en (med inloggning) i userInfo; släpp aldrig igenom dem.
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ProviderError.unreachable
        }
        switch status {
        case 200..<300: return data
        case 401, 403: throw ProviderError.unauthorized
        default: throw ProviderError.http(status)
        }
    }

    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private func makeURL(action: String?, extra: [(String, String)]) throws -> URL {
        guard var c = URLComponents(url: server, resolvingAgainstBaseURL: false) else { throw ProviderError.invalidResponse }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path + "/player_api.php"
        var pairs: [(String, String)] = [("username", username), ("password", password)]
        if let action { pairs.append(("action", action)) }
        pairs += extra
        c.percentEncodedQuery = pairs.map { k, v in
            k + "=" + (v.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? "")
        }.joined(separator: "&")
        guard let url = c.url else { throw ProviderError.invalidResponse }
        return url
    }
}

// Credentials får aldrig hamna i loggar eller dumpar.
extension XtreamClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "XtreamClient(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
