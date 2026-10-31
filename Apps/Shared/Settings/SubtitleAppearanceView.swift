import PlaybackCore
import SwiftUI

/// Textutseende för externa undertexter: storlek, färg och bakgrund, med förhandsvisning. Sparas i den aktiva
/// profilens inställningar. Dolt för barnprofiler (nås bara från inställningarna för vuxenprofiler).
struct SubtitleAppearanceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            if !model.kidsRestricted {
                Section("Preview") {
                    SubtitlePreview(appearance: model.settings.subtitleAppearance)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    Picker("Size", selection: $model.settings.subtitleAppearance.size) {
                        ForEach(SubtitleAppearance.Size.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Color", selection: $model.settings.subtitleAppearance.palette) {
                        ForEach(SubtitleAppearance.Palette.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Background", selection: $model.settings.subtitleAppearance.background) {
                        ForEach(SubtitleAppearance.Background.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            }
        }
        .navigationTitle(Text("Subtitle appearance"))
    }
}

/// Exempeltext över en bildlik bakgrund, ritad med valt utseende.
struct SubtitlePreview: View {
    let appearance: SubtitleAppearance

    var body: some View {
        ZStack {
            LinearGradient(colors: [.gray, .black], startPoint: .top, endPoint: .bottom)
            sample.padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, minHeight: previewHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("This is how subtitles will look."))
    }

    @ViewBuilder private var sample: some View {
        let base = Text("This is how subtitles will look.")
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

    private var previewHeight: CGFloat {
        #if os(tvOS)
        return 220
        #else
        return 110
        #endif
    }
}

extension SubtitleAppearance.Size {
    var label: LocalizedStringKey {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra large"
        }
    }

    /// Punktstorlek i förhandsvisningen (tvOS ritas för tio fots avstånd).
    var pointSize: CGFloat {
        #if os(tvOS)
        let scale: CGFloat = 2
        #else
        let scale: CGFloat = 1
        #endif
        switch self {
        case .small: return 14 * scale
        case .medium: return 18 * scale
        case .large: return 24 * scale
        case .extraLarge: return 30 * scale
        }
    }
}

extension SubtitleAppearance.Palette {
    var label: LocalizedStringKey {
        switch self {
        case .white: return "White"
        case .yellow: return "Yellow"
        case .cyan: return "Cyan"
        }
    }

    var color: Color {
        switch self {
        case .white: return .white
        case .yellow: return .yellow
        case .cyan: return .cyan
        }
    }
}

extension SubtitleAppearance.Background {
    var label: LocalizedStringKey {
        switch self {
        case .none: return "None"
        case .shadow: return "Shadow"
        case .box: return "Box"
        }
    }
}
