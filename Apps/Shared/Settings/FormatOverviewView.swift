import Core
import Library
import Providers
import SwiftUI

/// Containerformat per spellista och typ (`PlaylistStats`), med andel i procent. Beräknas utanför huvudaktören.
struct FormatOverviewView: View {
    @Environment(AppModel.self) private var model

    @State private var summaries: [UUID: FormatSummary] = [:]
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        List {
            if loading {
                ProgressView()
            } else if failed {
                Text("The library could not be read.").foregroundStyle(.secondary)
            } else if model.playlists.isEmpty {
                Text("No playlists yet.").foregroundStyle(.secondary)
            }
            ForEach(model.playlists) { playlist in
                if let summary = summaries[playlist.id] {
                    Section {
                        KindRows(title: Text("Movies"), counts: summary.containersByKind[.movie])
                        KindRows(title: Text("Series episodes"), counts: summary.containersByKind[.series])
                        KindRows(title: Text("Live"), counts: summary.containersByKind[.live])
                    } header: {
                        Text(verbatim: playlist.name)
                    } footer: {
                        if playlist.kind == .xtream {
                            Text("Episodes are counted once they have been loaded.")
                        }
                    }
                }
            }
        }
        .navigationTitle(Text("Format overview"))
        .task { await load() }
    }

    private func load() async {
        let store = model.store, ids = model.playlists.map(\.id)
        do {
            summaries = try await offMain(priority: .utility) {
                var result: [UUID: FormatSummary] = [:]
                for id in ids { result[id] = try store.formatSummary(playlistID: id) }
                return result
            }
            failed = false
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
        loading = false
    }
}

private struct KindRows: View {
    let title: Text
    let counts: [String: Int]?

    private var sorted: [(container: String, count: Int)] {
        (counts ?? [:]).map { (container: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.container < $1.container }
    }

    var body: some View {
        let rows = sorted
        let total = rows.reduce(0) { $0 + $1.count }
        if total > 0 {
            title.font(.headline)
            ForEach(rows, id: \.container) { row in
                LabeledContent {
                    Text(verbatim: "\(row.count.formatted()) · "
                         + (Double(row.count) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                } label: {
                    Text(verbatim: row.container == "unknown" ? "?" : row.container.uppercased())
                }
            }
        }
    }
}
