import Core
import Foundation
import Library
import Providers
import Secrets

/// Översätter fel till fasta, lokaliserade meddelanden. Det underliggande felet, URL:er, servrar och
/// användarnamn interpoleras aldrig, så meddelandet kan visas utan att läcka något.
enum UserFacingError {
    static func message(for error: Error) -> String {
        switch error {
        case let e as ProviderError:
            switch e {
            case .unauthorized:
                String(localized: "Sign-in was rejected. Check the username and password.")
            case .accountExpired:
                String(localized: "The account has expired.")
            case .accountDisabled:
                String(localized: "The account is disabled.")
            case .unreachable:
                String(localized: "The server could not be reached. Check the address and your connection.")
            case .http:
                String(localized: "The server responded with an error. Try again later.")
            case .invalidResponse:
                String(localized: "The server sent a response that could not be read.")
            }
        case let e as ImportError:
            switch e {
            case .unknownPlaylist:
                String(localized: "The playlist no longer exists.")
            case .secretUnreadable:
                String(localized: "The sign-in details could not be read.")
            case .storageFailed:
                String(localized: "The library could not be saved on this device.")
            }
        case let e as CoreError:
            switch e {
            case .missingSecret:
                String(localized: "The sign-in details are missing. Remove the playlist and add it again.")
            case .secretKindMismatch:
                String(localized: "The playlist details do not match. Remove the playlist and add it again.")
            case .invalidURL:
                String(localized: "The address is not valid.")
            }
        case is KeychainError:
            String(localized: "The sign-in details could not be stored securely on this device.")
        default:
            String(localized: "Something went wrong. Try again.")
        }
    }
}
