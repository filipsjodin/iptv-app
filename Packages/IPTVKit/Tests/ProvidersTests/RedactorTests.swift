import Testing
import Foundation
import Core
@testable import Providers

private let secret = PlaylistSecret.xtream(server: URL(string: "http://203.0.113.7:8080")!, username: "myUser", password: "s3cr&t")

@Test func redactsEverywhere() {
    let r = Redactor.redact("GET http://203.0.113.7:8080/movie/myUser/s3cr&t/1.mkv?username=myUser&password=s3cr%26t failed", secret: secret)
    #expect(!r.contains("myUser")); #expect(!r.contains("s3cr")); #expect(!r.contains("203.0.113.7")); #expect(!r.contains("8080"))
    #expect(r.contains("REDACTED"))
}

@Test func providerErrorsNeverContainSecrets() {
    for e in [ProviderError.unreachable, .unauthorized, .http(500), .invalidResponse, .accountDisabled] {
        #expect(!String(describing: e).contains("myUser"))
    }
}

@Test func catchesEncodedVariants() {
    let s = PlaylistSecret.xtream(server: URL(string: "http://203.0.113.7:8080")!, username: "my user", password: "p@ss/w&rd+1")
    let text = "a=my%20user b=my+user d=p%40ss%2Fw%26rd%2B1 e=p%40ss%2fw%26rd%2b1 f=p@ss/w&rd+1 g=p%40ss%2Fw%26rd%2B1"
    let r = Redactor.redact(text, secret: s)
    for leak in ["my%20user", "my+user", "p%40ss", "p@ss", "rd%2B1", "rd+1"] {
        #expect(!r.contains(leak), "leaked \(leak)")
    }
}

@Test func hostWithAndWithoutPortAndIPv4() {
    let r1 = Redactor.redact("connect to 203.0.113.7:8080 then 203.0.113.7 and HTTP://203.0.113.7:8080/x", secret: secret)
    #expect(!r1.contains("203.0.113.7")); #expect(!r1.contains("8080"))
    let named = PlaylistSecret.xtream(server: URL(string: "https://Provider.Example.com:8443")!, username: "alice", password: "hunter22")
    let r2 = Redactor.redact("https://provider.example.com:8443/a https://provider.example.com/b", secret: named)
    #expect(!r2.lowercased().contains("provider.example")); #expect(!r2.contains("8443"))
}

@Test func keepsNonSecretParts() {
    let r = Redactor.redact("GET http://203.0.113.7:8080/player_api.php?action=get_vod_streams failed with 500", secret: secret)
    #expect(r == "GET http://REDACTED/player_api.php?action=get_vod_streams failed with 500")
    #expect(Redactor.redact("nothing to see", secret: secret) == "nothing to see")
}

@Test func redactsShortCredentialsToo() {
    let s = PlaylistSecret.xtream(server: URL(string: "http://h.example:80")!, username: "ab", password: "x")
    let r = Redactor.redact("ab/x/1", secret: s)
    #expect(r == "REDACTED/REDACTED/1")
}

@Test func redactsM3USecret() {
    let s = PlaylistSecret.m3u(url: URL(string: "http://10.0.0.5:8080/get.php?username=bob&password=pw%21x&type=m3u")!,
                               epgURL: URL(string: "http://epg.example.net/xmltv.php")!)
    let r = Redactor.redact("http://10.0.0.5:8080/live/bob/pw!x/1.ts http://epg.example.net/x", secret: s)
    for leak in ["10.0.0.5", "8080", "bob", "pw!x", "epg.example.net"] { #expect(!r.contains(leak)) }
}

@Test func secretDescriptionsAreRedacted() {
    let x = PlaylistSecret.xtream(server: URL(string: "http://203.0.113.7:8080")!, username: "myUser", password: "s3cr&t")
    let m = PlaylistSecret.m3u(url: URL(string: "http://203.0.113.7:8080/get.php?username=myUser&password=s3cr")!, epgURL: nil)
    var dumped = ""
    dump(x, to: &dumped)
    for s in [x, m] {
        for text in [String(describing: s), String(reflecting: s), "\(s)", String(describing: Mirror(reflecting: s).children.map { "\($0)" }), dumped] {
            for leak in ["myUser", "s3cr", "203.0.113.7", "8080"] { #expect(!text.contains(leak)) }
        }
    }
    #expect(String(describing: x) == "PlaylistSecret.xtream(<redacted>)")
    #expect(String(describing: m) == "PlaylistSecret.m3u(<redacted>)")
}

@Test func redactsM3UTokensInQueryAndPath() {
    let s = PlaylistSecret.m3u(url: URL(string: "http://cdn.example.net/u/abc123/playlist.m3u?token=abc123xyz&type=m3u_plus")!, epgURL: nil)
    let r = Redactor.redact("GET http://cdn.example.net/u/abc123/playlist.m3u?token=abc123xyz&type=m3u_plus ok /abc123/ abc123xyz", secret: s)
    for leak in ["abc123", "abc123xyz", "cdn.example.net"] { #expect(!r.contains(leak), "leaked \(leak)") }
    #expect(r.contains("playlist.m3u")); #expect(r.contains("type=m3u_plus"))
}

@Test func placeholdersSurviveTypicalCredentials() {
    let text = "http://example.invalid/live/REDACTED/REDACTED/1.ts"
    #expect(Redactor.redact(text, secret: secret) == text)
}

@Test func redactsIPv6HostWithBracketsAndPort() {
    let s = PlaylistSecret.xtream(server: URL(string: "http://[2001:db8::1]:8080")!, username: "alice1", password: "hunter22")
    let r = Redactor.redact("GET http://[2001:db8::1]:8080/x and [2001:db8::1] and 2001:db8::1", secret: s)
    #expect(!r.contains("2001")); #expect(!r.contains("8080")); #expect(!r.contains("db8"))
    #expect(r.hasPrefix("GET http://REDACTED/x"))
}
