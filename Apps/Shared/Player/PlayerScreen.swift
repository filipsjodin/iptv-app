import AVFoundation
import Core
import Playback
import PlaybackCore
import SwiftUI
import VLCEngine

/// Spelarvyn. Presenteras i helskärm (`.fullScreenCover`) av anroparen.
///
/// Skapar sessionen med spellistans hemlighet, anropar `tick()` varje sekund, pausar och sparar när appen
/// lämnar förgrunden och stoppar när vyn försvinner. Vid motorbyte byts värdvyn ut; sessionen behåller positionen.
struct PlayerScreen: View {
    let request: PlaybackRequest
    let playlistID: UUID
    let nextEpisodeProvider: (@MainActor () async -> PlaybackRequest?)?
    /// Bara live: kanallistan att zappa i.
    let zap: LiveZapContext?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: PlayerScreenModel?
    @State private var setupError: String?
    @State private var zapController: ZapController?
    @State private var channelInfo: ChannelInfoModel?

    init(request: PlaybackRequest, playlistID: UUID,
         nextEpisodeProvider: (@MainActor () async -> PlaybackRequest?)? = nil,
         zap: LiveZapContext? = nil) {
        self.request = request
        self.playlistID = playlistID
        self.nextEpisodeProvider = nextEpisodeProvider
        self.zap = zap
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let message = model?.revokedMessage {
                // Vakten gav anslutningen till en annan uppspelning; spelaren är stoppad.
                VStack(spacing: 24) {
                    Text(verbatim: message).multilineTextAlignment(.center)
                    Button("Close", action: close)
                }
                .padding()
            } else if let model {
                PlayerContent(model: model, onClose: close, zap: zapAction, channelInfo: channelInfo)
            } else if let setupError {
                VStack(spacing: 24) {
                    Text(verbatim: setupError).multilineTextAlignment(.center)
                    Button("Close", action: close)
                }
                .padding()
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task { await setUp() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                model?.tick()
            }
        }
        .onChange(of: scenePhase) { _, phase in model?.handleScenePhase(phase) }
        // Skärmsläckarspärren följer sessionens state direkt (och vid varje tick).
        .onChange(of: model?.session.state) { _, state in
            model?.applyIdleTimer()
            model?.observeBuffering()
            // Första bildrutan (eller ett misslyckat byte) avslutar `channelSwitch`-intervallet.
            if state == .playing || model?.session.errorMessageKey != nil { model?.endChannelSwitchSignpost() }
        }
        // Det definitiva stoppet sker i `close()`; detta är ett skyddat säkerhetsnät (inte under AVKits helskärm).
        // Stoppet släpper även skärmsläckarspärren.
        .onDisappear {
            // Zappningen avbryts bara när spelaren verkligen stoppas (inte vid bild-i-bild eller AVKits helskärm).
            if model?.viewDisappeared() == true {
                zapController?.cancel()
                channelInfo?.cancel()
            }
        }
        #if os(tvOS)
        // Menu/tillbaka avvisar först ett kvalitetsförslag på skärmen (utan att stänga spelaren).
        .onExitCommand {
            if model?.suggestLower != nil { model?.dismissSuggestion() } else { close() }
        }
        #endif
    }

    /// Zappning; nil utan zapplista (film, avsnitt, barnläge).
    private var zapAction: ((ZapController.Direction) -> Void)? {
        guard let zapController, let channelInfo else { return nil }
        return { direction in
            // Intervallet och infon startar bara när ett byte verkligen schemalagts.
            guard zapController.zap(direction) else { return }
            model?.beginChannelSwitchSignpost()
            channelInfo.show(zapController.current)
        }
    }

    private func close() {
        zapController?.cancel()
        channelInfo?.cancel()
        model?.stop()
        dismiss()
    }

    private func setUp() async {
        guard model == nil, setupError == nil else { return }
        let secret: PlaylistSecret
        do {
            secret = try await app.playbackSecret(for: playlistID)
        } catch is CancellationError {
            return
        } catch {
            setupError = UserFacingError.message(for: error)
            return
        }
        let settings = app.settings, userState = app.userState
        let recorder = EngineKindRecorder()
        let makeSession: @MainActor (PlaybackRequest) -> PlaybackSession = { request in
            PlaybackSession(request: request, secret: secret, settings: settings, userState: userState,
                            makeEngine: { kind in
                                recorder.last = kind
                                return Self.makeEngine(kind, title: request.title)
                            })
        }
        let model = PlayerScreenModel(session: makeSession(request), nextEpisodeProvider: nextEpisodeProvider,
                                      makeSession: makeSession, engineRecorder: recorder,
                                      broker: app.broker, playlistID: playlistID)
        self.model = model
        makeZapping(for: model)
        makeQualityMenu(for: model)
        makeSubtitleSupport(for: model)
        // Begär en anslutningsplats och startar sedan. Avbryts tasken (vyn försvinner) avbryter sessionen
        // laddningen och stänger motorn; platsen släpps i `stop()`.
        await model.start()
    }

    /// Zappning bara för live med minst två kanaler och bara utanför barnläge (djupförsvar; `request` ger då nil).
    private func makeZapping(for model: PlayerScreenModel) {
        guard let zap, request.isLive, !app.kidsRestricted,
              zap.groups.count > 1, zap.groups.contains(where: { $0.id == zap.start }) else { return }
        let controller = ZapController(
            groups: zap.groups, start: zap.start, request: zap.request,
            switchTo: { next in await model.switchChannel(to: next) },
            started: { zap.noteWatched($0) })
        zapController = controller
        let info = ChannelInfoModel(group: controller.current, loadNowNext: zap.nowNext)
        channelInfo = info
        info.show(controller.current)
    }

    /// Kvalitetsmeny och buffringsförslag bara för live utanför barnläge (djupförsvar: `liveRequest` ger då nil).
    private func makeQualityMenu(for model: PlayerScreenModel) {
        guard let zap, request.isLive, !app.kidsRestricted else { return }
        let playlistID = playlistID, app = app
        model.configureLive(groups: zap.groups, current: request.key.providerID,
                            displaySupportsHDR: AVPlayer.eligibleForHDRPlayback,
                            request: { group, variant in
                                app.liveRequest(group: group, variant: variant, playlistID: playlistID)
                            })
    }

    /// Undertextsökning, lagrade texter och synkjustering bara för filmer och avsnitt, med nyckel och utanför barnläge
    /// (djupförsvar: `AppModel` ger annars inget; `isAvailable` läses om vid varje användning). Barnläge: ingen koppling,
    /// alltså inga menyval och inga anrop.
    private func makeSubtitleSupport(for model: PlayerScreenModel) {
        guard !request.isLive, !app.kidsRestricted, app.subtitlesAvailable else { return }
        let playlistID = playlistID, app = app
        model.configureSubtitles(PlayerSubtitleSupport(
            request: request,
            isAvailable: { app.subtitlesAvailable },
            loadStored: { await app.storedSubtitles(for: $0, playlistID: playlistID) },
            saveOffset: { offset, request in
                await app.setSubtitleOffset(offset, for: request, playlistID: playlistID)
            },
            makeSearch: { request, onDownloaded in
                SubtitleSearchModel(request: request, playlistID: playlistID, app: app,
                                    preferredLanguages: app.settings.tracks.subtitleLanguages,
                                    onDownloaded: onDownloaded)
            }))
    }

    @MainActor
    private static func makeEngine(_ kind: EngineKind, title: String) -> any PlayerEngine {
        switch kind {
        // Titeln visas i Kontrollcenter/AirPlay; URL:en exponeras aldrig.
        case .avPlayer: AVPlayerEngine(title: title)
        case .vlc: VLCPlayerEngine(title: title)
        }
    }
}

/// Värdvy för aktuell motor plus overlayer för laddning, fel och nästa avsnitt.
private struct PlayerContent: View {
    @Environment(AppModel.self) private var app
    let model: PlayerScreenModel
    let onClose: () -> Void
    let zap: ((ZapController.Direction) -> Void)?
    let channelInfo: ChannelInfoModel?

    var body: some View {
        content
            .sheet(isPresented: subtitleSearchPresented) {
                // Samma blad på iOS och tvOS; Menu/tillbaka stänger bara bladet (se `SubtitleSearchSheet`).
                if let search = model.subtitleSearch {
                    SubtitleSearchSheet(model: search, onClose: { model.dismissSubtitleSearch() })
                }
            }
            #if os(iOS)
            // Vertikal svepning byter kanal (bara live). Samtidig gest, så att Apples kontroller fungerar som förut.
            .simultaneousGesture(
                DragGesture(minimumDistance: 50).onEnded { value in
                    let dy = value.translation.height
                    guard let zap, abs(dy) > abs(value.translation.width) * 1.5 else { return }
                    // Svep uppåt = nästa kanal i listan.
                    zap(dy < 0 ? .down : .up)
                },
                including: zap == nil ? .subviews : .all)
            #endif
    }

    private var subtitleSearchPresented: Binding<Bool> {
        // Läses här (under `body`), så att visningen följer modellen; Binding-closuren läses av SwiftUI senare.
        let presented = model.subtitleSearch != nil
        return Binding(get: { presented },
                       set: { [model] in if !$0 { model.dismissSubtitleSearch() } })
    }

    /// tvOS live: `ZapPressCatcher` äger fjärrkontrollen, så VLC-kontrollerna visas inte.
    private var zapOwnsRemote: Bool {
        #if os(tvOS)
        zap != nil
        #else
        false
        #endif
    }

    @ViewBuilder private var content: some View {
        let session = model.session
        ZStack {
            if let key = session.errorMessageKey {
                PlaybackErrorOverlay(messageKey: key, model: model, onClose: onClose)
            } else {
                if let engine = session.engine as? AVPlayerEngine {
                    AVPlayerHost(engine: engine, model: model, zapEnabled: zap != nil)
                        .id(ObjectIdentifier(engine))
                        .ignoresSafeArea()
                    // Externa undertexter ritas av oss ovanpå Apples spelare (inte över VLC, som ritar själv).
                    ExternalSubtitleOverlay(engine: engine, appearance: app.settings.subtitleAppearance)
                    #if os(iOS)
                    AVPlayerTopBar(model: model, onClose: onClose)
                    NextEpisodeOverlay(model: model)
                    #else
                    // Knapparna ligger som fasta contextualActions; sekunderna visas här.
                    NextEpisodeCountdownLabel(model: model)
                    #endif
                } else if let engine = session.engine as? VLCPlayerEngine {
                    VLCPlayerHost(engine: engine, model: model, onClose: onClose, showsControls: !zapOwnsRemote)
                        .id(ObjectIdentifier(engine))
                    NextEpisodeOverlay(model: model)
                }
            }
            if let channelInfo { ChannelInfoOverlay(model: channelInfo) }
            if session.errorMessageKey == nil { LowerQualitySuggestion(model: model) }
            #if os(tvOS)
            // Inte över felvyn: "Prova VLC/Apple" och "Stäng" ska nås med fjärrkontrollen.
            if let zap, session.errorMessageKey == nil { ZapPressCatcher(zap: zap, model: model) }
            #endif
            // Även över felvyn, så att "Prova VLC" visar att något händer.
            PlaybackLoadingOverlay(state: session.state)
        }
    }
}

#if os(iOS)
/// Stäng-knapp och menyknapp ovanpå Apples spelare på iOS.
private struct AVPlayerTopBar: View {
    let model: PlayerScreenModel
    let onClose: () -> Void

    var body: some View {
        VStack {
            HStack {
                Spacer()
                PlayerOptionsMenu(model: model)
                Button(action: onClose) {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.top, 56)
            Spacer()
        }
    }
}
#endif

#if os(tvOS)
/// tvOS, live: upp/ned på Siri Remote byter kanal, Select öppnar spelarmenyerna (ljud, undertexter, spelare, info)
/// i ett blad, och Play/Paus växlar uppspelningen. Fångar fokus eftersom live saknar skrubbkontroller; Menu
/// (tillbaka) hanteras av `PlayerScreen` som vanligt. Vyn finns bara när en zapplista finns (inte för VOD) och
/// visas inte över felvyn.
private struct ZapPressCatcher: View {
    let zap: (ZapController.Direction) -> Void
    let model: PlayerScreenModel
    @FocusState private var focused: Bool
    @State private var showMenus = false

    var body: some View {
        Button {
            // Med ett förslag på skärmen accepterar Select det; annars öppnas menyerna.
            if model.suggestLower != nil {
                Task { await model.acceptSuggestion() }
            } else {
                showMenus = true
            }
        } label: { Color.clear }
            .buttonStyle(.plain)
            .focused($focused)
            .onMoveCommand { direction in
                switch direction {
                case .up: zap(.up)
                case .down: zap(.down)
                default: break
                }
            }
            .onPlayPauseCommand { model.togglePlayPause() }
            .onAppear { focused = true }
            .onChange(of: showMenus) { _, shown in if !shown { focused = true } }
            .sheet(isPresented: $showMenus) { LivePlayerMenusSheet(model: model) }
    }
}

/// Spelarmenyerna (`PlayerScreenModel.menus`) som ett blad, så att ljud, undertexter och spelarval nås under live.
private struct LivePlayerMenusSheet: View {
    let model: PlayerScreenModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.menus) { menu in
                    Section {
                        PlayerMenuContent(menu: menu)
                    } header: {
                        Label(menu.title, systemImage: menu.systemImage)
                    }
                }
            }
        }
    }
}
#endif
