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
            // Första bildrutan (eller ett misslyckat byte) avslutar `channelSwitch`-intervallet.
            if state == .playing || model?.session.errorMessageKey != nil { model?.endChannelSwitchSignpost() }
        }
        // Det definitiva stoppet sker i `close()`; detta är ett skyddat säkerhetsnät (inte under AVKits helskärm).
        // Stoppet släpper även skärmsläckarspärren.
        .onDisappear {
            zapController?.cancel()
            channelInfo?.cancel()
            model?.viewDisappeared()
        }
        #if os(tvOS)
        .onExitCommand(perform: close)
        #endif
    }

    /// Zappning; nil utan zapplista (film, avsnitt, barnläge).
    private var zapAction: ((ZapController.Direction) -> Void)? {
        guard let zapController, let channelInfo else { return nil }
        return { direction in
            model?.beginChannelSwitchSignpost()
            zapController.zap(direction)
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
    let model: PlayerScreenModel
    let onClose: () -> Void
    let zap: ((ZapController.Direction) -> Void)?
    let channelInfo: ChannelInfoModel?

    var body: some View {
        content
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
                    #if os(iOS)
                    AVPlayerTopBar(model: model, onClose: onClose)
                    NextEpisodeOverlay(model: model)
                    #else
                    // Knapparna ligger som fasta contextualActions; sekunderna visas här.
                    NextEpisodeCountdownLabel(model: model)
                    #endif
                } else if let engine = session.engine as? VLCPlayerEngine {
                    VLCPlayerHost(engine: engine, model: model, onClose: onClose)
                        .id(ObjectIdentifier(engine))
                    NextEpisodeOverlay(model: model)
                }
            }
            if let channelInfo { ChannelInfoOverlay(model: channelInfo) }
            #if os(tvOS)
            if let zap { ZapPressCatcher(zap: zap, model: model) }
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
/// tvOS, live: upp/ned på Siri Remote byter kanal. Fångar fokus (inga skrubbkontroller för live) och tar
/// Play/Paus. VOD berörs inte: vyn finns bara när en zapplista finns.
private struct ZapPressCatcher: View {
    let zap: (ZapController.Direction) -> Void
    let model: PlayerScreenModel
    @FocusState private var focused: Bool

    var body: some View {
        Color.clear
            .focusable()
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
    }
}
#endif
