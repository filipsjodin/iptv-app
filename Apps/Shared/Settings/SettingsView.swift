import PlaybackCore
import SwiftUI

/// Uppspelningsinställningar. Varje ändring sparas direkt (`AppModel.settings` sparar vid `didSet`).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Player") {
                Picker("Default player", selection: $model.settings.engine) {
                    Text("Automatic").tag(EnginePreference.automatic)
                    Text("Apple's player").tag(EnginePreference.avPlayer)
                    Text(verbatim: "VLC").tag(EnginePreference.vlc)
                }
                NavigationLink("Compare players") { EngineComparisonView() }
            }
            Section("Audio") {
                NavigationLink {
                    LanguageListEditor(languages: $model.settings.tracks.audioLanguages)
                        .navigationTitle(Text("Audio languages"))
                } label: {
                    LabeledContent("Audio languages") {
                        Text(verbatim: LanguageOptions.summary(model.settings.tracks.audioLanguages))
                    }
                }
                Toggle("Prefer Atmos/surround", isOn: $model.settings.tracks.preferSurround)
            }
            Section("Subtitles") {
                Picker("Subtitles", selection: $model.settings.tracks.subtitleMode) {
                    Text("Off").tag(SubtitleMode.off)
                    Text("Always").tag(SubtitleMode.always)
                    Text("Only for foreign audio").tag(SubtitleMode.foreignAudioOnly)
                }
                NavigationLink {
                    LanguageListEditor(languages: $model.settings.tracks.subtitleLanguages)
                        .navigationTitle(Text("Subtitle languages"))
                } label: {
                    LabeledContent("Subtitle languages") {
                        Text(verbatim: LanguageOptions.summary(model.settings.tracks.subtitleLanguages))
                    }
                }
            }
            Section("Library") {
                NavigationLink("Format overview") { FormatOverviewView() }
            }
        }
        .navigationTitle(Text("Settings"))
    }
}

/// Vanliga språk att välja bland (ISO 639-1), och visningsnamn på användarens språk.
enum LanguageOptions {
    static let common = ["sv", "en", "no", "da", "fi", "de", "fr", "es", "it", "ar", "tr", "pl", "nl", "pt", "ru"]

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }

    static func summary(_ codes: [String]) -> String {
        codes.map(name).joined(separator: ", ")
    }
}

/// Ordnad språklista: lägg till från vanliga språk, ta bort och flytta. iOS: redigeringsläge med dra och
/// svep; tvOS: en meny per rad med Flytta upp/ned och Ta bort.
struct LanguageListEditor: View {
    @Binding var languages: [String]

    private var available: [String] { LanguageOptions.common.filter { !languages.contains($0) } }

    var body: some View {
        List {
            Section {
                if languages.isEmpty {
                    Text("No languages selected.").foregroundStyle(.secondary)
                }
                #if os(tvOS)
                ForEach(languages, id: \.self) { code in
                    let index = languages.firstIndex(of: code) ?? 0
                    Menu {
                        Button("Move Up", systemImage: "arrow.up") { move(index, by: -1) }
                            .disabled(index == 0)
                        Button("Move Down", systemImage: "arrow.down") { move(index, by: 1) }
                            .disabled(index == languages.count - 1)
                        Button("Remove", systemImage: "trash", role: .destructive) { languages.remove(at: index) }
                    } label: {
                        row(index: index, code: code)
                    }
                }
                #else
                ForEach(languages, id: \.self) { code in
                    row(index: languages.firstIndex(of: code) ?? 0, code: code)
                }
                .onDelete { languages.remove(atOffsets: $0) }
                .onMove { languages.move(fromOffsets: $0, toOffset: $1) }
                #endif
            } header: {
                Text("In order of preference")
            }
            if !available.isEmpty {
                Section("Add Language") {
                    ForEach(available, id: \.self) { code in
                        Button {
                            languages.append(code)
                        } label: {
                            Label(LanguageOptions.name(code), systemImage: "plus")
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }

    private func row(index: Int, code: String) -> some View {
        HStack {
            Text(verbatim: "\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
            Text(verbatim: LanguageOptions.name(code))
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard languages.indices.contains(index), languages.indices.contains(target) else { return }
        languages.swapAt(index, target)
    }
}
