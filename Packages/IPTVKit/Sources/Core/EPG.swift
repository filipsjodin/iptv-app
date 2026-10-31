import Foundation

/// Ett tablåprogram (EPG) för en kanal. `end` är alltid efter `start`.
public struct EPGProgram: Sendable, Hashable, Codable {
    public var channelID: String
    public var start: Date
    public var end: Date
    public var title: String
    public var summary: String?

    public init(channelID: String, start: Date, end: Date, title: String, summary: String? = nil) {
        self.channelID = channelID
        self.start = start
        self.end = end
        self.title = title
        self.summary = summary
    }
}

/// En XMLTV-kanal med alla sina visningsnamn i dokumentordning.
public struct EPGChannel: Sendable, Hashable {
    public var id: String
    public var names: [String]

    public init(id: String, names: [String]) {
        self.id = id
        self.names = names
    }
}

/// Pågående och nästa program för en kanal.
public struct NowNext: Sendable, Hashable {
    public var now: EPGProgram?
    public var next: EPGProgram?

    public init(now: EPGProgram? = nil, next: EPGProgram? = nil) {
        self.now = now
        self.next = next
    }
}
