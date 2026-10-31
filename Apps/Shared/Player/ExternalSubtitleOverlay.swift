import Playback
import PlaybackCore
import Subtitles
import SwiftUI

/// Ritar vald extern undertext ovanpå Apples spelare (AVPlayer har ingen egen läsning av externa filer). VLC ritar
/// sina externa texter själv och får ingen överlagring. Utan vald extern text ritas ingenting.
///
/// En `TimelineView` med 0,2 s takt gör uppslaget; `body` innehåller bara ett uppslag (binärsökning i cues) och
/// ingen läsning av fil, databas eller nätverk. Motorns `externalCueProvider` fångar spår och förskjutning vid
/// anropet och läses därför på nytt vid varje uppslag.
struct ExternalSubtitleOverlay: View {
    let engine: AVPlayerEngine
    let appearance: SubtitleAppearance

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            if let text = Self.currentText(engine: engine) {
                ExternalSubtitleText(text: text, appearance: appearance)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, bottomPadding)
            }
        }
        .allowsHitTesting(false)
    }

    /// Cuen som gäller nu, eller nil när ingen extern text är vald eller ingen cue täcker tidpunkten. Läser
    /// `externalCueProvider` på nytt varje gång.
    @MainActor
    static func currentText(engine: any PlayerEngine) -> String? {
        guard let provider = engine.externalCueProvider else { return nil }
        return provider(engine.currentTime)?.text
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        return 120
        #else
        return 24
        #endif
    }

    /// Ovanför Apples reglage.
    private var bottomPadding: CGFloat {
        #if os(tvOS)
        return 90
        #else
        return 64
        #endif
    }
}

/// Texten med valt utseende (storlek, färg, bakgrund), samma som förhandsvisningen i inställningarna.
struct ExternalSubtitleText: View {
    let text: String
    let appearance: SubtitleAppearance

    var body: some View {
        let base = Text(verbatim: text)
            .font(.system(size: appearance.size.pointSize, weight: .semibold))
            .foregroundStyle(appearance.palette.color)
            .multilineTextAlignment(.center)
        switch appearance.background {
        case .none:
            base
        case .shadow:
            base.shadow(color: .black, radius: 2, x: 1, y: 1)
        case .box:
            base
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
