import Downloads

/// Knappens utseende. `.hidden` när nedladdningar inte finns (tvOS, barnprofil, ingen profil).
enum DownloadButtonState: Equatable {
    case hidden, available, queued, downloading(Double), paused, completed, failed
}

/// Ren avbildning från nedladdningens tillstånd till knappens. Ingen vy- eller plattformskod, så den testas direkt.
struct DownloadButtonModel {
    static func state(for state: DownloadState?, available: Bool) -> DownloadButtonState {
        guard available else { return .hidden }
        guard let state else { return .available }
        switch state {
        case .queued: return .queued
        case let .downloading(progress): return .downloading(min(max(progress, 0), 1))
        case .paused: return .paused
        case .completed: return .completed
        case .failed: return .failed
        }
    }
}

#if !os(tvOS)
import Core
import SwiftUI

/// Nedladdningsknapp för en film eller ett avsnitt. Ikonen följer tillståndet (hämta, kö, förlopp, pausad,
/// klar, misslyckad). Hämta och försök igen startar `start`; övriga tillstånd öppnar en meny för att ta bort.
/// Fel visas som övriga åtgärders (`UserFacingError`). Inget loggas.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let kind: ContentKind
    let providerID: String
    let playlistID: UUID
    /// Liten variant för en rad (bara ikon).
    var compact = false
    let start: () async throws -> Void

    @State private var working = false

    private var key: DownloadKey? {
        model.activeProfile.map {
            DownloadKey(profileID: $0.profile.id, playlistID: playlistID, kind: kind, providerID: providerID)
        }
    }

    private var state: DownloadButtonState {
        guard let key else { return .hidden }
        return DownloadButtonModel.state(for: model.downloadState(for: key), available: model.downloadsAvailable)
    }

    var body: some View {
        let state = state
        if state != .hidden {
            Group {
                switch state {
                case .available, .failed:
                    Button(action: begin) { label(state) }
                        .disabled(working)
                default:
                    Menu {
                        Button(removeTitle(state), systemImage: "trash", role: .destructive) { remove() }
                    } label: {
                        label(state)
                    }
                }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text(accessibility(state)))
        }
    }

    @ViewBuilder
    private func label(_ state: DownloadButtonState) -> some View {
        if compact {
            icon(state)
        } else {
            Label {
                Text(title(state))
            } icon: {
                icon(state)
            }
        }
    }

    @ViewBuilder
    private func icon(_ state: DownloadButtonState) -> some View {
        switch state {
        case let .downloading(progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .frame(width: 18, height: 18)
        default:
            Image(systemName: symbol(state))
        }
    }

    private func symbol(_ state: DownloadButtonState) -> String {
        switch state {
        case .hidden, .available: "arrow.down.circle"
        case .queued: "clock"
        case .downloading: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func title(_ state: DownloadButtonState) -> String {
        switch state {
        case .hidden, .available: String(localized: "Download")
        case .queued: String(localized: "Queued")
        case .downloading: String(localized: "Downloading")
        case .paused: String(localized: "Paused")
        case .completed: String(localized: "Downloaded")
        case .failed: String(localized: "Try Again")
        }
    }

    private func accessibility(_ state: DownloadButtonState) -> String {
        if case let .downloading(progress) = state {
            return String(localized: "Downloading \(Int(progress * 100)) percent")
        }
        return title(state)
    }

    private func removeTitle(_ state: DownloadButtonState) -> String {
        state == .completed ? String(localized: "Remove download") : String(localized: "Cancel download")
    }

    private func begin() {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await start()
            } catch is CancellationError {
                return
            } catch {
                model.lastError = UserFacingError.message(for: error)
            }
        }
    }

    private func remove() {
        guard let key else { return }
        Task { await model.removeDownload(key) }
    }
}
#endif
