import Core
import Foundation
import Library
import Playback
import PlaybackCore
import Subtitles
import SwiftUI
import Testing
@testable import IPTVApp

/// Lokal motor med stöd för externa undertexter. `PlaybackTestSupport` länkas inte in i testbundeln (se
/// `TestEngine`), så `FakeEngine` kan inte användas här.
@MainActor
final class ExternalTestEngine: PlayerEngine {
    let kind: EngineKind
    private(set) var state: PlaybackState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var currentTime: Double = 0
    private(set) var duration: Double?
    let audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudioID: String?
    private(set) var selectedSubtitleID: String?
    let videoInfo: VideoInfo = .unknown
    var onStateChange: ((PlaybackState) -> Void)?
    private var externals = ExternalSubtitleSet()
    private(set) var subtitleOffset: Double = 0
    private(set) var addedFileIDs: [Int] = []

    init(kind: EngineKind) { self.kind = kind }

    func load(url: URL, startAt: Double?) async throws {
        externals.removeAll()
        subtitleTracks = []
        subtitleOffset = 0
        duration = 1000
        currentTime = startAt ?? 0
        state = .playing
    }
    func play() { state = .playing }
    func pause() { state = .paused }
    func seek(to seconds: Double) async { currentTime = seconds }
    func select(audioID: String?) { selectedAudioID = audioID }
    func select(subtitleID: String?) { selectedSubtitleID = subtitleID }
    func close() { state = .idle }

    func addExternalSubtitle(fileURL: URL, language: String?, title: String, fileID: Int) async throws {
        guard state != .idle else { throw ExternalSubtitleError.notLoaded }
        let cues = try await ExternalSubtitleLoader.load(fileURL)
        let track = externals.add(fileID: fileID, language: language, title: title, cues: cues)
        if !subtitleTracks.contains(where: { $0.id == track.id }) { subtitleTracks.append(track) }
        addedFileIDs.append(fileID)
    }

    var externalCueProvider: ((Double) -> SubtitleCue?)? {
        externals.cueProvider(selectedID: selectedSubtitleID, offset: subtitleOffset)
    }

    func setSubtitleOffset(_ seconds: Double) { subtitleOffset = SubtitleTrack.clampOffset(seconds) }
}

/// Motorerna som sessionen skapat, i ordning.
@MainActor
final class ExternalEngineLog {
    var engines: [ExternalTestEngine] = []
    var latest: ExternalTestEngine? { engines.last }
}

private let subSecret = PlaylistSecret.xtream(server: URL(string: "http://h:1")!, username: "u", password: "p")

private func movie(_ id: String = "101") -> PlaybackRequest {
    PlaybackRequest(key: ProgressKey(playlistID: UUID(), kind: .movie, providerID: id), title: id,
                    locator: .xtream(kind: .movie, streamID: id, container: "mp4"), container: "mp4", isLive: false)
}

@MainActor
private func externalSession(_ request: PlaybackRequest, log: ExternalEngineLog) -> PlaybackSession {
    PlaybackSession(request: request, secret: subSecret, settings: PlaybackSettings(engine: .avPlayer),
                    userState: InMemoryUserStateStore(),
                    makeEngine: { kind in
                        let engine = ExternalTestEngine(kind: kind)
                        log.engines.append(engine)
                        return engine
                    },
                    audioSession: AudioSessionControl(activate: {}, deactivate: {}))
}

/// En SRT-fil med en cue (1–3 s) i en egen mapp.
private func writeSubtitleFile(_ fileID: Int) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("player-sub-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(fileID).srt")
    try "1\n00:00:01,000 --> 00:00:03,000\nHej\n".write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func stored(_ fileID: Int) throws -> StoredSubtitle {
    StoredSubtitle(id: fileID, language: "sv", release: "Rel\(fileID)", addedAt: Date(timeIntervalSince1970: 0),
                   fileURL: try writeSubtitleFile(fileID))
}

/// Appens undertextskoppling med räknare, utan databas och nätverk.
@MainActor
private final class SupportFixture {
    var available = true
    var storedSubs: [StoredSubtitle] = []
    var storedOffset = 0.0
    private(set) var loadCalls = 0
    private(set) var savedOffsets: [Double] = []
    private(set) var searchModelsMade = 0
    let search = SearchBackendStub()

    func support(for request: PlaybackRequest) -> PlayerSubtitleSupport {
        PlayerSubtitleSupport(
            request: request,
            isAvailable: { [self] in available },
            loadStored: { [self] _ in
                loadCalls += 1
                return (storedSubs, storedOffset)
            },
            saveOffset: { [self] offset, _ in savedOffsets.append(offset) },
            makeSearch: { [self] _, onDownloaded in
                searchModelsMade += 1
                return SubtitleSearchModel(backend: search.backend, preferredLanguages: ["sv"],
                                           onDownloaded: onDownloaded)
            })
    }
}

@MainActor
struct PlayerScreenModelSubtitleTests {
    private func makeModel(_ fixture: SupportFixture, log: ExternalEngineLog, request: PlaybackRequest = movie())
        -> PlayerScreenModel
    {
        let model = PlayerScreenModel(session: externalSession(request, log: log), nextEpisodeProvider: nil,
                                      makeSession: { externalSession($0, log: log) },
                                      setIdleTimerDisabled: { _ in })
        model.configureSubtitles(fixture.support(for: request))
        return model
    }

    private func subtitleOptionIDs(_ model: PlayerScreenModel) -> [String] {
        model.menus.first { $0.id == "subtitle" }?.options.map(\.id) ?? []
    }

    @Test func kidsProfileCannotPresentSearch() async throws {
        let fixture = SupportFixture()
        fixture.available = false   // barnläge eller ingen nyckel
        fixture.storedSubs = [try stored(11)]
        let log = ExternalEngineLog()
        let model = makeModel(fixture, log: log)
        await model.start()

        #expect(!subtitleOptionIDs(model).contains("subtitle.search"))
        model.presentSubtitleSearch()
        #expect(model.subtitleSearch == nil)
        #expect(fixture.searchModelsMade == 0)
        // Inga lagrade texter hämtas, ingen förskjutning sparas.
        await model.adjustSubtitleOffset(by: 0.1)
        #expect(fixture.loadCalls == 0)
        #expect(fixture.savedOffsets.isEmpty)
        #expect(model.subtitleOffset == 0)
        #expect(log.latest?.addedFileIDs.isEmpty == true)

        // Med funktionen tillgänglig finns menyvalet och bladet öppnas.
        fixture.available = true
        #expect(subtitleOptionIDs(model).contains("subtitle.search"))
        model.presentSubtitleSearch()
        #expect(model.subtitleSearch != nil)
        #expect(fixture.searchModelsMade == 1)
        model.dismissSubtitleSearch()
        #expect(model.subtitleSearch == nil)
    }

    @Test func storedSubtitlesAttachedOnStart() async throws {
        let fixture = SupportFixture()
        fixture.storedSubs = [try stored(11), try stored(12)]
        fixture.storedOffset = 0.5
        let log = ExternalEngineLog()
        let model = makeModel(fixture, log: log)
        await model.start()

        let engine = try #require(log.latest)
        #expect(engine.addedFileIDs == [11, 12])
        #expect(engine.subtitleTracks.map(\.id) == ["ext:11", "ext:12"])
        #expect(engine.subtitleOffset == 0.5)
        #expect(model.subtitleOffset == 0.5)
        #expect(fixture.loadCalls == 1)
    }

    @Test func offsetAdjustsInTenthsAndPersists() async throws {
        let fixture = SupportFixture()
        fixture.storedSubs = [try stored(11)]
        let log = ExternalEngineLog()
        let model = makeModel(fixture, log: log)
        await model.start()
        let engine = try #require(log.latest)

        await model.adjustSubtitleOffset(by: 0.1)
        await model.adjustSubtitleOffset(by: 0.1)
        await model.adjustSubtitleOffset(by: 0.1)
        #expect(model.subtitleOffset == 0.3)   // inget flyttalsbrus: avrundas till tiondelar
        #expect(engine.subtitleOffset == 0.3)
        #expect(fixture.savedOffsets == [0.1, 0.2, 0.3])

        // Menyns tecken är användarens: "+" fördröjer texten, vilket är en MINSKNING av motorns förskjutning.
        await model.adjustSubtitleDelay(by: 0.1)
        #expect(model.subtitleOffset == 0.2)
        #expect(model.subtitleDelay == -0.2)   // visas som "−0,2 s": texten kommer tidigare än i filen
        #expect(engine.subtitleOffset == 0.2)

        await model.resetSubtitleOffset()
        #expect(model.subtitleOffset == 0)
        #expect(engine.subtitleOffset == 0)
        #expect(fixture.savedOffsets.last == 0)

        // Klampas till ±600 s.
        await model.adjustSubtitleOffset(by: 10_000)
        #expect(model.subtitleOffset == 600)
    }

    @Test func syncMenuOnlyWithExternalSubtitleSelected() async throws {
        let fixture = SupportFixture()
        fixture.storedSubs = [try stored(11)]
        let log = ExternalEngineLog()
        let model = makeModel(fixture, log: log)
        await model.start()

        model.session.selectSubtitle(nil)   // spårvalet kan annars ha valt den lagrade texten själv
        #expect(subtitleOptionIDs(model).contains("subtitle.search"))
        #expect(!subtitleOptionIDs(model).contains("subtitle.sync.later"))

        model.session.selectSubtitle("ext:11")
        let ids = subtitleOptionIDs(model)
        #expect(ids.contains("subtitle.sync.value"))
        #expect(ids.contains("subtitle.sync.earlier"))
        #expect(ids.contains("subtitle.sync.later"))
        #expect(ids.contains("subtitle.sync.reset"))
    }

    @Test func offsetSurvivesEngineSwitch() async throws {
        let fixture = SupportFixture()
        fixture.storedSubs = [try stored(11)]
        let log = ExternalEngineLog()
        let model = makeModel(fixture, log: log)
        await model.start()
        await model.adjustSubtitleOffset(by: 0.1)
        await model.adjustSubtitleOffset(by: 0.1)
        let first = try #require(log.latest)
        #expect(first.subtitleOffset == 0.2)

        await model.switchEngine(to: .vlc)

        let second = try #require(log.latest)
        #expect(second !== first)
        #expect(second.kind == .vlc)
        #expect(second.subtitleOffset == 0.2)
        #expect(second.subtitleTracks.map(\.id) == ["ext:11"])
        #expect(model.subtitleOffset == 0.2)
    }

    @Test func downloadAppliesAndSelectsTrack() async throws {
        let fixture = SupportFixture()
        let downloaded = try stored(21)
        fixture.search.stored = downloaded
        let found = osResult(21)
        fixture.search.results = [found]
        let log = ExternalEngineLog()
        let model = makeModel(fixture, log: log)
        await model.start()
        let engine = try #require(log.latest)
        #expect(engine.subtitleTracks.isEmpty)

        model.presentSubtitleSearch()
        let search = try #require(model.subtitleSearch)
        await search.search()
        #expect(search.phase == .results([found]))
        await search.download(found)

        // Texten är tillagd, vald och i bruk, och bladet är stängt.
        #expect(engine.subtitleTracks.map(\.id) == ["ext:21"])
        #expect(engine.selectedSubtitleID == "ext:21")
        #expect(model.subtitleSearch == nil)
        engine.currentTime = 2
        #expect(ExternalSubtitleOverlay.currentText(engine: engine) == "Hej")

        // Nästa uppstart (omstart/motorbyte) behåller den nedladdade texten.
        await model.switchEngine(to: .vlc)
        #expect(log.latest?.subtitleTracks.map(\.id) == ["ext:21"])
    }

    @Test func kidsSwitchMidDownloadDoesNotAttachOrSelect() async throws {
        let fixture = SupportFixture()
        fixture.search.stored = try stored(31)
        let found = osResult(31)
        fixture.search.results = [found]
        let log = ExternalEngineLog()
        let model = makeModel(fixture, log: log)
        await model.start()
        let engine = try #require(log.latest)

        model.presentSubtitleSearch()
        let search = try #require(model.subtitleSearch)
        await search.search()
        // Profilen byts till barnprofil medan nedladdningen pågår.
        fixture.search.beforeDownloadReturns = { fixture.available = false }
        await search.download(found)

        #expect(engine.subtitleTracks.isEmpty)
        #expect(engine.addedFileIDs.isEmpty)
        #expect(engine.selectedSubtitleID == nil)
    }

    @Test func overlayHiddenWhenNoExternalSelected() async throws {
        let fixture = SupportFixture()
        fixture.storedSubs = [try stored(11)]
        let log = ExternalEngineLog()
        let model = makeModel(fixture, log: log)
        await model.start()
        let engine = try #require(log.latest)
        engine.currentTime = 2

        // Spåret finns men ingen extern text är vald: ingen överlagring.
        engine.select(subtitleID: nil)
        #expect(ExternalSubtitleOverlay.currentText(engine: engine) == nil)

        engine.select(subtitleID: "ext:11")
        #expect(ExternalSubtitleOverlay.currentText(engine: engine) == "Hej")
        engine.currentTime = 5   // ingen cue vid 5 s
        #expect(ExternalSubtitleOverlay.currentText(engine: engine) == nil)

        // Fördröjning +1 s ("+" i menyn): cuen (1–3 s) visas först vid 2–4 s. Förskjutningen läses på nytt vid
        // varje uppslag, så ändringen syns direkt.
        await model.adjustSubtitleDelay(by: 1)
        engine.currentTime = 1.5
        #expect(ExternalSubtitleOverlay.currentText(engine: engine) == nil)
        engine.currentTime = 3.5
        #expect(ExternalSubtitleOverlay.currentText(engine: engine) == "Hej")

        engine.select(subtitleID: nil)
        #expect(ExternalSubtitleOverlay.currentText(engine: engine) == nil)
    }

    @Test func delayTextShowsUserDirection() {
        #expect(PlayerScreenModel.delayText(0).hasPrefix("0"))
        #expect(PlayerScreenModel.delayText(0.3).contains("+"))
        #expect(!PlayerScreenModel.delayText(-0.3).contains("+"))
    }
}
