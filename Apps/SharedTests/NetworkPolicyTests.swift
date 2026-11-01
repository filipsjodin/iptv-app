#if !os(tvOS)
import Testing
@testable import IPTVApp

struct NetworkPolicyTests {
    @Test func wifiIsWifi() {
        let status = NetworkStatus.make(isSatisfied: true, usesWifi: true, usesWired: false, isExpensive: false)
        #expect(status == NetworkStatus(isOnline: true, isOnWifi: true))
    }

    @Test func wiredCountsAsWifi() {
        let status = NetworkStatus.make(isSatisfied: true, usesWifi: false, usesWired: true, isExpensive: false)
        #expect(status.isOnWifi)
        #expect(status.isOnline)
    }

    @Test func cellularIsOnlineButNotWifi() {
        let status = NetworkStatus.make(isSatisfied: true, usesWifi: false, usesWired: false, isExpensive: true)
        #expect(status.isOnline)
        #expect(!status.isOnWifi)
    }

    @Test func expensiveWifiHotspotIsNotWifi() {
        let status = NetworkStatus.make(isSatisfied: true, usesWifi: true, usesWired: false, isExpensive: true)
        #expect(status.isOnline)
        #expect(!status.isOnWifi)
    }

    @Test func unsatisfiedPathIsOfflineEvenOnWifiInterface() {
        let status = NetworkStatus.make(isSatisfied: false, usesWifi: true, usesWired: true, isExpensive: false)
        #expect(status == .offline)
        #expect(!status.isOnline)
        #expect(!status.isOnWifi)
    }

    @Test func offlineStatusCanNeverBeWifi() {
        #expect(!NetworkStatus(isOnline: false, isOnWifi: true).isOnWifi)
    }
}
#endif
