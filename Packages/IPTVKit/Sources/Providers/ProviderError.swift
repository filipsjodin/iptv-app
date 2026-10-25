import Foundation

/// Fel från en leverantör. Varken fallen eller `description` innehåller URL:er, värdnamn eller inloggning.
public enum ProviderError: Error, Equatable, CustomStringConvertible {
    case unauthorized
    case accountExpired(Date)
    case accountDisabled
    case unreachable
    case http(Int)
    case invalidResponse

    public var description: String {
        switch self {
        case .unauthorized: "Inloggningen nekades"
        case .accountExpired: "Kontot har gått ut"
        case .accountDisabled: "Kontot är avstängt"
        case .unreachable: "Servern kan inte nås"
        case let .http(code): "Servern svarade med HTTP \(code)"
        case .invalidResponse: "Ogiltigt svar från servern"
        }
    }
}
