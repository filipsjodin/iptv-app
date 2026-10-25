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

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: PlayerScreenModel?
    @State private var setupError: String?

    init(request: PlaybackRequest, playlistID: UUID,
         nextEpisodeProvider: (@MainActor () async -> PlaybackRequest?)? = nil) {
        self.request = request
        self.playlistID = playlistID
        self.nextEpisodeProvider = nextEpisodeProvider
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                PlayerContent(model: model, onClose: close)
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { model?.pauseAndSave() }
        }
        .onDisappear { model?.stop() }
        #if os(tvOS)
        .onExitCommand(perform: close)
        #endif
    }

    private func close() {
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
                                return Self.makeEngine(kind)
                            })
        }
        let model = PlayerScreenModel(session: makeSession(request), nextEpisodeProvider: nextEpisodeProvider,
                                      makeSession: makeSession, engineRecorder: recorder)
        self.model = model
        // Avbryts tasken (vyn försvinner) avbryter sessionen laddningen och stänger motorn.
        await model.start()
    }

    @MainActor
    private static func makeEngine(_ kind: EngineKind) -> any PlayerEngine {
        switch kind {
        case .avPlayer: AVPlayerEngine()
        case .vlc: VLCPlayerEngine()
        }
    }
}

/// Värdvy för aktuell motor plus overlayer för laddning, fel och nästa avsnitt.
private struct PlayerContent: View {
    let model: PlayerScreenModel
    let onClose: () -> Void

    var body: some View {
        let session = model.session
        ZStack {
            if let key = session.errorMessageKey {
                PlaybackErrorOverlay(messageKey: key, model: model, onClose: onClose)
            } else {
                if let engine = session.engine as? AVPlayerEngine {
                    AVPlayerHost(engine: engine, model: model)
                        .id(ObjectIdentifier(engine))
                        .ignoresSafeArea()
                    #if os(iOS)
                    AVPlayerTopBar(model: model, onClose: onClose)
                    NextEpisodeOverlay(model: model)
                    #endif
                } else if let engine = session.engine as? VLCPlayerEngine {
                    VLCPlayerHost(engine: engine, model: model, onClose: onClose)
                        .id(ObjectIdentifier(engine))
                    NextEpisodeOverlay(model: model)
                }
                PlaybackLoadingOverlay(state: session.state)
            }
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
