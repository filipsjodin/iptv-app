import Foundation
import Observation
import Personal
import PlaybackCore

/// En vald profils personliga data: tittarpositioner, Min lista/betyg och uppspelningsinställningar, alla under
/// profilens egna nycklar (`ProfileKeys`). `AppModel` skapar exakt en instans per profil och cachar den, så att
/// två lager aldrig skriver över varandra under samma nyckel.
@MainActor @Observable
final class ProfileSession {
    /// Uppdateras av `AppModel.updateProfile` (namn, avatar, barnprofil, PIN); id:t ändras aldrig.
    private(set) var profile: Profile
    let userState: any UserStateStore
    let personal: any PersonalStore
    /// Sparas vid varje ändring under profilens nyckel.
    var settings: PlaybackSettings {
        didSet { settings.save(to: defaults, key: ProfileKeys.settings(profile.id)) }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(profile: Profile, defaults: UserDefaults) {
        self.profile = profile
        self.defaults = defaults
        userState = UserDefaultsUserStateStore(defaults: defaults, key: ProfileKeys.progress(profile.id))
        personal = UserDefaultsPersonalStore(defaults: defaults, key: ProfileKeys.personal(profile.id))
        settings = PlaybackSettings.load(from: defaults, key: ProfileKeys.settings(profile.id))
    }

    func update(_ profile: Profile) {
        precondition(profile.id == self.profile.id)
        self.profile = profile
    }
}

/// Fel vid profilval och profilhantering. Fasta beskrivningar; PIN-koden förekommer aldrig.
enum ProfileError: Error, Equatable, Sendable {
    case wrongPin
    case notFound
    /// PIN måste vara exakt fyra siffror.
    case invalidPin
}

/// Ändring av en profils PIN i profilredigeraren.
enum PinChange: Equatable, Sendable {
    case keep
    case set(String)
    case remove
}

/// Flikarna i biblioteket. Live döljs för barnprofiler.
enum LibraryTab: Hashable, Sendable {
    case movies, series, live

    static func visible(isKids: Bool) -> [LibraryTab] {
        isKids ? [.movies, .series] : [.movies, .series, .live]
    }
}

/// Avatarer att välja bland i profilredigeraren (SF Symbols).
enum ProfileAvatars {
    static let all = ["person.crop.circle", "person.fill", "face.smiling", "star.fill", "heart.fill", "pawprint.fill",
                      "gamecontroller.fill", "film.fill", "tv.fill", "music.note", "leaf.fill", "bolt.fill"]
}

/// Giltig PIN: exakt fyra siffror (0–9).
func isValidPin(_ pin: String) -> Bool {
    pin.utf8.count == 4 && pin.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
}
