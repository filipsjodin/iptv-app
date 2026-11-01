import Foundation

/// Översätter systemfel till fasta `DownloadFailure`-värden. Ren logik: tar (domän, kod)-par för felet och dess
/// underliggande fel, så att den kan testas utan Apples ramverk.
public enum DownloadErrorMapping {
    public struct Code: Sendable, Equatable {
        public var domain: String
        public var code: Int
        public init(domain: String, code: Int) {
            self.domain = domain
            self.code = code
        }
    }

    /// Slut på utrymme eller filen kan inte skrivas: `NSURLErrorCannotCreateFile` (-3000),
    /// `NSURLErrorCannotWriteToFile` (-3003), `NSFileWriteOutOfSpaceError` (640), `ENOSPC` (28).
    public static func isOutOfSpace(_ chain: [Code]) -> Bool {
        chain.contains { c in
            switch c.domain {
            case "NSURLErrorDomain": return c.code == -3000 || c.code == -3003
            case "NSCocoaErrorDomain": return c.code == 640
            case "NSPOSIXErrorDomain": return c.code == 28
            default: return false
            }
        }
    }

    /// Fel från sessionen: utrymmesfel -> `noSpace`, övriga URL-fel -> `network`, resten -> `unknown`.
    public static func sessionFailure(_ chain: [Code]) -> DownloadFailure {
        if isOutOfSpace(chain) { return .noSpace }
        return chain.first?.domain == "NSURLErrorDomain" ? .network : .unknown
    }

    /// Fel vid flytt till mellanlagring: utrymmesfel -> `noSpace`, annars `storage`.
    public static func storageFailure(_ chain: [Code]) -> DownloadFailure {
        isOutOfSpace(chain) ? .noSpace : .storage
    }
}
