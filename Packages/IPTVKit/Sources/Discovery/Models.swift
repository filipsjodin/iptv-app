import Foundation
import Core
import Personal

public struct Candidate: Sendable, Hashable {
    public var ref: ItemRef
    public var tmdbID: Int?
    public var title: String
    public var genres: [Int]
    public var castIDs: [Int]
    public var directorIDs: [Int]
    public var keywords: [String]
    public var ageLimit: Int?
    public var addedAt: Date?
    public var popularity: Double?

    public init(ref: ItemRef, tmdbID: Int?, title: String, genres: [Int], castIDs: [Int], directorIDs: [Int],
                keywords: [String], ageLimit: Int?, addedAt: Date?, popularity: Double?) {
        self.ref = ref
        self.tmdbID = tmdbID
        self.title = title
        self.genres = genres
        self.castIDs = castIDs
        self.directorIDs = directorIDs
        self.keywords = keywords
        self.ageLimit = ageLimit
        self.addedAt = addedAt
        self.popularity = popularity
    }
}

public struct Signals: Sendable {
    /// Andel sedd, 0 till 1.
    public var watched: [ItemRef: Double]
    public var ratings: [ItemRef: Rating]
    public var myList: Set<ItemRef>
    public var recommendationsFor: [ItemRef: [Int]]

    public init(watched: [ItemRef: Double] = [:], ratings: [ItemRef: Rating] = [:], myList: Set<ItemRef> = [],
                recommendationsFor: [ItemRef: [Int]] = [:]) {
        self.watched = watched
        self.ratings = ratings
        self.myList = myList
        self.recommendationsFor = recommendationsFor
    }
}

public enum RowID: Hashable, Sendable {
    case continueWatching
    case forYou
    case topTen(ContentKind)
    case recentlyAdded(ContentKind)
    case myList
    case genre(Int, ContentKind)
}

/// Deterministisk ordning för tie-breaks: `kind.rawValue`, sedan `providerID`.
func refLess(_ a: ItemRef, _ b: ItemRef) -> Bool {
    if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
    return a.providerID < b.providerID
}
