#if canImport(os)
import os

/// Delad signposter för tablåns mätpunkter (`epgImport`, `epgQuery`); `channelSwitch` finns i spelaren.
enum EPGSignpost {
    static let signposter = OSSignposter(subsystem: "se.sjodin.iptv", category: "epg")
}
#endif
