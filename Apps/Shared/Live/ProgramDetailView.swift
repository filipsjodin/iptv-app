import Core
import Providers
import SwiftUI

/// Ett program i tablån: titel, tid och beskrivning, och "Titta nu" bara när programmet sänds just nu.
/// Tiden är redan formaterad (cachad per program) och `now` tas när programmet väljs, så ingen formatering eller
/// klocka läses i `body`.
struct ProgramDetailView: View {
    let group: ChannelGroup
    let cell: EPGCell
    let now: Date
    let watch: () -> Void
    let close: () -> Void

    /// Programmet sänds nu (`start <= now < end`).
    var isAiring: Bool { cell.program.start <= now && now < cell.program.end }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                ChannelLogoView(group: group, size: CGSize(width: 84, height: 52))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: cell.program.title).font(.title2.bold())
                    Text(verbatim: group.displayName).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text(verbatim: cell.rangeText).font(.headline).foregroundStyle(.secondary)
            if let summary = cell.program.summary, !summary.isEmpty {
                ScrollView { Text(verbatim: summary).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                Text("No description").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 20) {
                if isAiring {
                    Button("Watch now", systemImage: "play.fill", action: watch)
                        .buttonStyle(.borderedProminent)
                }
                Button("Close", action: close)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
