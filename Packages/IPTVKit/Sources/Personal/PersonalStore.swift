import Foundation
import Core

public struct ItemRef: Codable, Hashable, Sendable {
    public var kind: ContentKind
    public var providerID: String
    public init(kind: ContentKind, providerID: String) {
        self.kind = kind
        self.providerID = providerID
    }
}

public enum Rating: String, Codable, Sendable { case up, down }

public protocol PersonalStore: Sendable {
    /// Nyast först.
    func myList() -> [ItemRef]
    /// Returnerar `true` om posten finns i listan efter anropet.
    func toggleMyList(_ item: ItemRef) -> Bool
    func isInMyList(_ item: ItemRef) -> Bool
    func rating(_ item: ItemRef) -> Rating?
    func setRating(_ rating: Rating?, for item: ItemRef)
    func ratings() -> [ItemRef: Rating]
}

struct RatingEntry: Codable { var item: ItemRef; var rating: Rating }

struct PersonalSnapshot: Codable {
    /// Äldst först (nyast sist); `myList()` vänder ordningen.
    var list: [ItemRef] = []
    /// Äldst först; äldsta betyg släpps vid överskridande av kapaciteten.
    var rated: [RatingEntry] = []
}

public final class UserDefaultsPersonalStore: PersonalStore, @unchecked Sendable {
    // @unchecked Sendable: UserDefaults är trådsäkert men inte annoterat Sendable på alla plattformar;
    // `snap` skyddas av `lock`. En JSON-blob under `key`; skadad data ger tomma listor.
    public static let defaultMyListCapacity = 1000
    public static let defaultRatingsCapacity = 2000
    private let myListCapacity: Int
    private let ratingsCapacity: Int

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var snap: PersonalSnapshot

    public convenience init(defaults: UserDefaults, key: String) {
        self.init(defaults: defaults, key: key, myListCapacity: Self.defaultMyListCapacity, ratingsCapacity: Self.defaultRatingsCapacity)
    }

    /// Intern: injicerbara kapaciteter (för tester).
    init(defaults: UserDefaults, key: String, myListCapacity: Int, ratingsCapacity: Int) {
        self.myListCapacity = myListCapacity
        self.ratingsCapacity = ratingsCapacity
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(PersonalSnapshot.self, from: data) {
            snap = s
        } else {
            snap = PersonalSnapshot()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snap) { defaults.set(data, forKey: key) }
    }

    public func myList() -> [ItemRef] { lock.withLock { Array(snap.list.reversed()) } }

    public func toggleMyList(_ item: ItemRef) -> Bool {
        lock.withLock {
            defer { persist() }
            if let i = snap.list.firstIndex(of: item) {
                snap.list.remove(at: i)
                return false
            }
            snap.list.append(item)
            if snap.list.count > myListCapacity { snap.list.removeFirst(snap.list.count - myListCapacity) }
            return true
        }
    }

    public func isInMyList(_ item: ItemRef) -> Bool { lock.withLock { snap.list.contains(item) } }

    public func rating(_ item: ItemRef) -> Rating? {
        lock.withLock { snap.rated.first { $0.item == item }?.rating }
    }

    public func setRating(_ rating: Rating?, for item: ItemRef) {
        lock.withLock {
            snap.rated.removeAll { $0.item == item }
            if let rating {
                snap.rated.append(RatingEntry(item: item, rating: rating))
                if snap.rated.count > ratingsCapacity { snap.rated.removeFirst(snap.rated.count - ratingsCapacity) }
            }
            persist()
        }
    }

    public func ratings() -> [ItemRef: Rating] {
        lock.withLock { Dictionary(snap.rated.map { ($0.item, $0.rating) }, uniquingKeysWith: { $1 }) }
    }
}
