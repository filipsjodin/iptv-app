#if !os(tvOS)
import SwiftUI

/// En rad i Nedladdningar: affisch (lokal fil), titel, tillstånd, förlopp, storlek och åtgärdsknappar.
/// Raden får färdiga värden av `DownloadsViewModel`; den läser ingenting själv.
struct DownloadRow: View {
    let row: DownloadsViewModel.Row
    let isRegular: Bool
    let perform: (DownloadsViewModel.Action) -> Void

    private var posterSize: CGSize { isRegular ? CGSize(width: 64, height: 96) : CGSize(width: 48, height: 72) }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: nil, kind: .poster, placeholderSystemImage: "film")
                .preferringLocalFile(row.posterURL)
                .frame(width: posterSize.width, height: posterSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.title).font(.headline).lineLimit(2)
                if let subtitle = row.subtitle {
                    Text(verbatim: subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let progress = row.progress, row.state != .completed {
                    ProgressView(value: progress)
                }
                HStack(spacing: 6) {
                    Text(verbatim: row.statusText)
                    if !row.sizeText.isEmpty {
                        Text(verbatim: "·")
                        Text(verbatim: row.sizeText)
                    }
                }
                .font(.caption)
                .foregroundStyle(isProblem ? Color.red : Color.secondary)
            }
            Spacer(minLength: 0)
            trailingButton
        }
        .contentShape(Rectangle())
    }

    private var isProblem: Bool {
        switch row.state {
        case .failed, .lowDiskSpace: true
        default: false
        }
    }

    /// Spela, pausa eller återuppta direkt i raden; radering finns i svep och kontextmeny.
    @ViewBuilder private var trailingButton: some View {
        if let action = row.actions.first(where: { $0 == .play || $0 == .pause || $0 == .resume }) {
            Button { perform(action) } label: {
                Image(systemName: DownloadRow.symbol(for: action, state: row.state)).imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(DownloadRow.label(for: action, state: row.state))
        }
    }

    static func symbol(for action: DownloadsViewModel.Action, state: DownloadsViewModel.RowState) -> String {
        switch action {
        case .play: "play.circle"
        case .pause: "pause.circle"
        case .resume:
            if case .failed = state { "arrow.clockwise.circle" } else { "arrow.down.circle" }
        case .cancel, .delete: "trash"
        }
    }

    static func label(for action: DownloadsViewModel.Action, state: DownloadsViewModel.RowState) -> LocalizedStringKey {
        switch action {
        case .play: "Play"
        case .pause: "Pause"
        case .resume:
            if case .failed = state { "Retry" } else { "Resume" }
        case .cancel: "Cancel download"
        case .delete: "Delete"
        }
    }
}
#endif
