#if os(tvOS)
import Core
import Providers
import SwiftUI

/// Högra rutan i tvOS-kanallistan: liten liveförhandsvisning av den fokuserade kanalen (tyst, samma yta som
/// titelförhandsvisningen) med programnamn, beskrivning och tid under. Videon visas bara när kontrollern spelar;
/// annars syns kanalens logga på mörk botten. Rent presentation: inget nätverk eller databas, allt kommer färdigt
/// från `LiveModel`.
struct ChannelPreview: View {
    let group: ChannelGroup?
    let nowNext: NowNext?
    let controller: PreviewController?

    private static let size = CGSize(width: 640, height: 360)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            screen
            if let group {
                Text(verbatim: group.displayName).font(.title3.bold()).lineLimit(1)
            }
            programInfo
            Spacer(minLength: 0)
        }
        .frame(width: Self.size.width, alignment: .topLeading)
    }

    private var screen: some View {
        ZStack {
            Color.black
            if let group {
                ChannelLogoView(group: group, size: CGSize(width: 220, height: 132))
            }
            if let controller {
                PreviewSurface(controller: controller)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder private var programInfo: some View {
        if let program = nowNext?.now ?? nowNext?.next {
            let isNow = nowNext?.now != nil
            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringKey(isNow ? "Now" : "Next")).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: program.title).font(.headline).lineLimit(2)
                Text(verbatim: Self.timeRange(program)).font(.subheadline).foregroundStyle(.secondary)
                if let summary = program.summary, !summary.isEmpty {
                    Text(verbatim: summary).font(.callout).foregroundStyle(.secondary).lineLimit(5)
                }
            }
        }
    }

    /// "20:00–21:00" i enhetens tidsformat.
    static func timeRange(_ program: EPGProgram) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(program.start.formatted(style))\u{2013}\(program.end.formatted(style))"
    }
}
#endif
