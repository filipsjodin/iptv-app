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
    /// Sparas vid varje ändring under profilens nyckel (inte efter att profilen tagits bort).
    var settings: PlaybackSettings {
        didSet {
            guard !deleted else { return }
            settings.save(to: defaults, key: ProfileKeys.settings(profile.id))
            settingsDidChange?()
        }
    }
    /// Anropas efter att inställningarna sparats (`AppModel` skickar nedladdningsinställningarna vidare).
    @ObservationIgnored var settingsDidChange: (@MainActor () -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let progressStore: ProfileUserStateStore
    @ObservationIgnored private let personalStore: ProfilePersonalStore
    @ObservationIgnored private(set) var deleted = false

    init(profile: Profile, defaults: UserDefaults) {
        self.profile = profile
        self.defaults = defaults
        let progressStore = ProfileUserStateStore(
            UserDefaultsUserStateStore(defaults: defaults, key: ProfileKeys.progress(profile.id)))
        let personalStore = ProfilePersonalStore(
            UserDefaultsPersonalStore(defaults: defaults, key: ProfileKeys.personal(profile.id)))
        self.progressStore = progressStore
        self.personalStore = personalStore
        userState = progressStore
        personal = personalStore
        settings = PlaybackSettings.load(from: defaults, key: ProfileKeys.settings(profile.id))
    }

    /// Profilen tas bort: lagren slutar skriva, så att en uppspelning som fortfarande håller sessionens lager
    /// (t.ex. bild-i-bild) inte återskapar profilens nycklar efter borttagningen.
    func invalidate() {
        deleted = true
        progressStore.invalidate()
        personalStore.invalidate()
    }

    func update(_ profile: Profile) {
        precondition(profile.id == self.profile.id)
        self.profile = profile
    }
}

/// Profilens tittarpositioner. Efter `invalidate()` ignoreras alla skrivningar (läsningar fungerar).
final class ProfileUserStateStore: UserStateStore, @unchecked Sendable {
    // @unchecked Sendable: `invalidated` skyddas av `lock`, som hålls över skrivningen så att ingen skrivning
    // hinner ske efter att `invalidate()` returnerat.
    private let inner: any UserStateStore
    private let lock = NSLock()
    private var invalidated = false

    init(_ inner: any UserStateStore) { self.inner = inner }

    func invalidate() { lock.withLock { invalidated = true } }

    func progress(for key: ProgressKey) -> WatchProgress? { inner.progress(for: key) }
    func save(_ progress: WatchProgress) {
        lock.withLock { if !invalidated { inner.save(progress) } }
    }
    func continueWatching(playlistID: UUID, limit: Int) -> [WatchProgress] {
        inner.continueWatching(playlistID: playlistID, limit: limit)
    }
    func lastWatchedEpisode(playlistID: UUID, seriesProviderID: String) -> WatchProgress? {
        inner.lastWatchedEpisode(playlistID: playlistID, seriesProviderID: seriesProviderID)
    }
    func entries(playlistID: UUID) -> [WatchProgress] { inner.entries(playlistID: playlistID) }
    func remove(playlistID: UUID) {
        lock.withLock { if !invalidated { inner.remove(playlistID: playlistID) } }
    }
}

/// Profilens Min lista och betyg. Efter `invalidate()` ignoreras alla skrivningar.
final class ProfilePersonalStore: PersonalStore, @unchecked Sendable {
    // @unchecked Sendable: `invalidated` skyddas av `lock` (hålls över skrivningen).
    private let inner: any PersonalStore
    private let lock = NSLock()
    private var invalidated = false

    init(_ inner: any PersonalStore) { self.inner = inner }

    func invalidate() { lock.withLock { invalidated = true } }

    func myList() -> [ItemRef] { inner.myList() }
    func toggleMyList(_ item: ItemRef) -> Bool {
        lock.withLock { invalidated ? inner.isInMyList(item) : inner.toggleMyList(item) }
    }
    func isInMyList(_ item: ItemRef) -> Bool { inner.isInMyList(item) }
    func rating(_ item: ItemRef) -> Rating? { inner.rating(item) }
    func setRating(_ rating: Rating?, for item: ItemRef) {
        lock.withLock { if !invalidated { inner.setRating(rating, for: item) } }
    }
    func ratings() -> [ItemRef: Rating] { inner.ratings() }
    func favoriteChannels() -> [String] { inner.favoriteChannels() }
    func toggleFavoriteChannel(_ groupID: String) -> Bool {
        lock.withLock { invalidated ? inner.favoriteChannels().contains(groupID) : inner.toggleFavoriteChannel(groupID) }
    }
    func recentChannels() -> [String] { inner.recentChannels() }
    func noteChannelWatched(_ groupID: String) {
        lock.withLock { if !invalidated { inner.noteChannelWatched(groupID) } }
    }
}

/// Fel vid profilval och profilhantering. Fasta beskrivningar; PIN-koden förekommer aldrig.
enum ProfileError: Error, Equatable, Sendable {
    case wrongPin
    /// För många felaktiga försök i rad; nya försök avvisas en stund.
    case tooManyAttempts
    case notFound
    /// PIN måste vara exakt fyra siffror.
    case invalidPin
    /// Profilhantering är inte tillåten när en barnprofil är aktiv.
    case notAllowed
    /// Utan aktiv profil kräver profilhanteringen PIN-koden för en vuxenprofil.
    case adultPinRequired
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
