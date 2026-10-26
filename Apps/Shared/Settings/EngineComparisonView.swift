import SwiftUI

/// Jämförelse mellan Apples spelare och VLC-motorn (spec §7.1).
struct EngineComparisonView: View {
    private struct Row: Identifiable {
        let id: Int
        let feature: LocalizedStringResource
        let apple: LocalizedStringResource
        let vlc: LocalizedStringResource
    }

    private static let rows: [Row] = [
        Row(id: 0, feature: "Format", apple: "HLS, MP4/MOV (TS via HLS)",
            vlc: "Almost anything: MKV, AVI, TS, unusual codecs"),
        Row(id: 1, feature: "Dolby Vision", apple: "Yes",
            vlc: "No (HDR10 is shown, Dolby Vision data is dropped)"),
        Row(id: 2, feature: "HDR10/HLG", apple: "Yes", vlc: "Yes (limited)"),
        Row(id: 3, feature: "Dolby Atmos", apple: "Yes (E-AC-3 JOC)", vlc: "Limited"),
        Row(id: 4, feature: "Picture in Picture, system controls", apple: "Yes", vlc: "No / own controls"),
        Row(id: 5, feature: "Subtitle formats", apple: "WebVTT/embedded, external via own rendering",
            vlc: "SRT, ASS, PGS and more"),
    ]

    var body: some View {
        List {
            Section {
                Text("In automatic mode Apple's player is used when the format is supported. Otherwise, or if playback fails, the VLC engine takes over. You can switch player during playback.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Self.rows) { row in
                Section {
                    LabeledContent {
                        Text(row.apple).multilineTextAlignment(.trailing)
                    } label: {
                        Text("Apple's player")
                    }
                    LabeledContent {
                        Text(row.vlc).multilineTextAlignment(.trailing)
                    } label: {
                        Text(verbatim: "VLC")
                    }
                } header: {
                    Text(row.feature)
                }
            }
        }
        .navigationTitle(Text("Compare players"))
    }
}
