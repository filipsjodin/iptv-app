import Foundation
import Testing
@testable import Downloads
import PlaybackCore

@Suite struct AutomationRulesTests {
    private let on = DownloadSettings(wifiOnly: false, autoDeleteWatched: true, autoNextEpisode: true)
    private let off = DownloadSettings(wifiOnly: false, autoDeleteWatched: false, autoNextEpisode: false)

    @Test func deleteAfterWatchOnlyAtThresholdAndWhenEnabled() {
        let t = ProgressPolicy.watchedFraction
        #expect(DownloadAutomation.shouldDeleteAfterWatch(settings: on, watchedFraction: t))
        #expect(DownloadAutomation.shouldDeleteAfterWatch(settings: on, watchedFraction: 1))
        #expect(!DownloadAutomation.shouldDeleteAfterWatch(settings: on, watchedFraction: t.nextDown))
        #expect(!DownloadAutomation.shouldDeleteAfterWatch(settings: on, watchedFraction: 0))
        #expect(!DownloadAutomation.shouldDeleteAfterWatch(settings: on, watchedFraction: .nan))
        #expect(!DownloadAutomation.shouldDeleteAfterWatch(settings: off, watchedFraction: 1))
    }

    @Test func nextEpisodeOnlyOnWifiAndWhenEnabled() {
        #expect(DownloadAutomation.nextEpisodeToFetch(settings: on, onWifi: true, hasQueuedOrActive: false,
                                                      nextUndownloaded: "e2") == "e2")
        #expect(DownloadAutomation.nextEpisodeToFetch(settings: on, onWifi: false, hasQueuedOrActive: false,
                                                      nextUndownloaded: "e2") == nil)
        #expect(DownloadAutomation.nextEpisodeToFetch(settings: off, onWifi: true, hasQueuedOrActive: false,
                                                      nextUndownloaded: "e2") == nil)
        // Mobildata är aldrig tillåtet, även när "bara wifi" är av.
        var cellular = on
        cellular.wifiOnly = false
        #expect(DownloadAutomation.nextEpisodeToFetch(settings: cellular, onWifi: false, hasQueuedOrActive: false,
                                                      nextUndownloaded: "e2") == nil)
    }

    @Test func noNextWhenQueueBusy() {
        #expect(DownloadAutomation.nextEpisodeToFetch(settings: on, onWifi: true, hasQueuedOrActive: true,
                                                      nextUndownloaded: "e2") == nil)
    }

    @Test func noNextAtSeriesEnd() {
        #expect(DownloadAutomation.nextEpisodeToFetch(settings: on, onWifi: true, hasQueuedOrActive: false,
                                                      nextUndownloaded: nil) == nil)
    }
}
