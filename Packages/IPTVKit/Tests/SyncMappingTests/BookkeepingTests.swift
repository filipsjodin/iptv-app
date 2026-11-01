import Foundation
import Testing
import Sync
@testable import SyncMapping

@Test func bookkeepingRoundTripsThroughJSON() throws {
    var a = SyncableState(deviceID: "A")
    a.profiles[uuid(1)] = makeProfile(1)
    a.settings[uuid(1)] = .init()
    a.deleteProfile(uuid(1), now: at(10))
    a.deletePlaylist(uuid(100), now: at(20))
    a.origins[SyncMapper.profileID(uuid(2))] = .init(origin: "B", updatedAt: at(5))

    let data = try JSONEncoder().encode(a.bookkeeping)
    let decoded = try JSONDecoder().decode(SyncBookkeeping.self, from: data)

    var b = SyncableState(deviceID: "A")
    b.bookkeeping = decoded
    #expect(b.deletedProfiles == a.deletedProfiles)
    #expect(b.deletedPlaylists == a.deletedPlaylists)
    #expect(b.childTombstones == a.childTombstones)
    #expect(b.origins == a.origins)
    #expect(b.bookkeeping == a.bookkeeping)
}
