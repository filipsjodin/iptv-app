import Core
import Personal
import PlaybackCore
import SwiftUI

/// Profiler, uppspelningsinställningar för den aktiva profilen och TMDB-status. Varje ändring sparas direkt
/// (profilsessionen sparar vid `didSet`).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ProfilesSection()
            if model.activeProfile != nil {
                PlaybackSections()
            } else {
                Section("Player") {
                    Text("Choose a profile to change its player settings.").foregroundStyle(.secondary)
                }
            }
            Section("Library") {
                NavigationLink("Format overview") { FormatOverviewView() }
                LabeledContent {
                    Text(verbatim: metadataStatus)
                } label: {
                    Text(verbatim: "TMDB")
                }
            }
        }
        .navigationTitle(Text("Settings"))
        .task { await model.refreshMetadataStatus() }
    }

    /// "Saknar nyckel", "Nyckeln nekades", "Aktiverad" eller antal matchade titlar.
    private var metadataStatus: String {
        guard model.metadataConfigured else { return String(localized: "Missing key") }
        guard model.metadataAccepted else { return String(localized: "Key rejected") }
        guard let matched = model.matchedTitles else { return String(localized: "Enabled") }
        return String(localized: "Enabled · \(matched) matched titles")
    }
}

/// Profiler per spellista: aktiv profil, "Byt profil", ändra och lägg till. När en barnprofil är aktiv finns
/// bara "Byt profil" (en profil med PIN kräver koden vid bytet).
private struct ProfilesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Profile") {
            if let active = model.activeProfile {
                LabeledContent("Active profile") {
                    Label {
                        Text(verbatim: active.profile.name)
                    } icon: {
                        Image(systemName: active.profile.avatar)
                    }
                }
                Button("Switch Profile", systemImage: "person.2") { model.switchProfile() }
            } else {
                Text("No profile selected.").foregroundStyle(.secondary)
            }
        }
        ForEach(model.playlists.filter { model.canManageProfiles(playlistID: $0.id) }) { playlist in
            Section {
                ForEach(model.profiles(for: playlist.id)) { profile in
                    NavigationLink {
                        ProfileEditorView(mode: .edit(profile))
                    } label: {
                        Label {
                            Text(verbatim: profile.name)
                        } icon: {
                            Image(systemName: profile.avatar)
                        }
                    }
                }
                NavigationLink {
                    ProfileEditorView(mode: .add(playlistID: playlist.id))
                } label: {
                    Label("Add Profile", systemImage: "plus")
                }
            } header: {
                Text("Profiles · \(playlist.name)")
            }
        }
    }
}

/// Den aktiva profilens uppspelningsinställningar.
private struct PlaybackSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Player") {
            Picker("Default player", selection: $model.settings.engine) {
                Text("Automatic").tag(EnginePreference.automatic)
                Text("Apple's player").tag(EnginePreference.avPlayer)
                Text(verbatim: "VLC").tag(EnginePreference.vlc)
            }
            NavigationLink("Compare players") { EngineComparisonView() }
        }
        Section {
            Toggle("Previews", isOn: $model.settings.previewsEnabled)
            Toggle("Sound in previews", isOn: $model.settings.previewSoundEnabled)
                .disabled(!model.settings.previewsEnabled)
        } header: {
            Text("Previews")
        } footer: {
            Text("Short previews of the focused title play on Home and the detail page.")
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
        #if !os(tvOS)
        DownloadSettingsView()
        #endif
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
            // Nedladdning och utseende finns aldrig för barnprofiler.
            if !model.kidsRestricted {
                NavigationLink("Subtitle downloads") { OpenSubtitlesSettingsView() }
                NavigationLink("Subtitle appearance") { SubtitleAppearanceView() }
            }
        }
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
