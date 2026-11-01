#if !os(tvOS)
import PlaybackCore
import SwiftUI

/// Fliken Nedladdningar (iOS/iPadOS): förlopp, tillstånd, storlek och ledigt utrymme. Raderna kommer färdiga ur
/// `DownloadsViewModel`; inget hämtas i `body`. Att spela öppnar `PlayerScreen` med en offlinebegäran.
struct DownloadsView: View {
    let playlistID: UUID
    @State private var viewModel: DownloadsViewModel
    @State private var width: CGFloat = 0

    init(model: AppModel, manager: DownloadManager, playlistID: UUID) {
        self.playlistID = playlistID
        _viewModel = State(initialValue: DownloadsViewModel(model: model, manager: manager))
    }

    private var isRegular: Bool { LayoutMetrics(availableWidth: Double(width)).isRegular }

    var body: some View {
        // `@Bindable` ger bindningar till modellens `presented` och `message`.
        @Bindable var viewModel = viewModel
        let sections = viewModel.sections
        Group {
            if sections.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                       description: Text("Downloaded movies and episodes appear here and can be played offline."))
            } else {
                list(sections)
            }
        }
        .navigationTitle("Downloads")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task { await viewModel.refresh() }
        .playerCover($viewModel.presented, playlistID: playlistID, onDismiss: { Task { await viewModel.refresh() } })
        .alert(viewModel.message ?? "", isPresented: Binding(get: { viewModel.message != nil },
                                                              set: { if !$0 { viewModel.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func list(_ sections: [DownloadsViewModel.Section]) -> some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        DownloadRow(row: row, isRegular: isRegular) { action in run(action, row) }
                            .onTapGesture { if row.canPlay { run(.play, row) } }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                ForEach(row.actions.filter { $0 == .delete || $0 == .cancel }, id: \.self) { action in
                                    Button(role: .destructive) { run(action, row) } label: {
                                        Label(DownloadRow.label(for: action, state: row.state),
                                              systemImage: "trash")
                                    }
                                }
                            }
                            .contextMenu {
                                ForEach(row.actions, id: \.self) { action in
                                    Button(role: action == .delete || action == .cancel ? .destructive : nil) {
                                        run(action, row)
                                    } label: {
                                        Label(DownloadRow.label(for: action, state: row.state),
                                              systemImage: DownloadRow.symbol(for: action, state: row.state))
                                    }
                                }
                            }
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                HStack {
                    Text(verbatim: viewModel.totalSizeText)
                    Spacer()
                    Text(verbatim: viewModel.freeSpaceText)
                }
            }
        }
        .listStyle(.insetGrouped)
        // iPad: läsbar bredd, centrerad.
        .frame(maxWidth: isRegular ? 820 : .infinity)
        .frame(maxWidth: .infinity)
    }

    private func run(_ action: DownloadsViewModel.Action, _ row: DownloadsViewModel.Row) {
        Task { await viewModel.perform(action, on: row) }
    }
}
#endif
