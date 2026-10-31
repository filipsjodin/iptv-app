import Foundation
import Core

/// Var en lista hämtar sin programguide (XMLTV) ifrån.
public enum EPGSource {
    /// Xtream: `<server>/xmltv.php?username=&password=`; M3U: `epgURL` (kan saknas).
    /// Resultatet innehåller inloggning och får aldrig loggas.
    public static func url(for secret: PlaylistSecret) -> URL? {
        switch secret {
        case let .xtream(server, username, password):
            guard var comps = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
            var path = comps.path
            while path.hasSuffix("/") { path.removeLast() }
            comps.path = path + "/xmltv.php"
            // URLComponents kodar inte `&`, `+` och `=` i query-värden; gör det själva.
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
            comps.percentEncodedQuery = [("username", username), ("password", password)]
                .map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&")
            return comps.url
        case let .m3u(_, epgURL):
            return epgURL
        }
    }
}
