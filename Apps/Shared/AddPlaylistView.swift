import Core
import SwiftUI

/// Formulär för en ny spellista: Xtream Codes (server, användarnamn, lösenord) eller M3U-URL (+ valfri EPG-URL).
/// På tvOS ger systemet fjärrkontroll- och Continuity-tangentbord automatiskt för `TextField`/`SecureField`.
struct AddPlaylistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var input = PlaylistInput()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $input.kind) {
                        Text("Xtream Codes").tag(PlaylistInput.Kind.xtream)
                        Text("M3U URL").tag(PlaylistInput.Kind.m3u)
                    }
                    .pickerStyle(.segmented)
                    TextField("Name", text: $input.name)
                }
                switch input.kind {
                case .xtream:
                    Section("Account") {
                        TextField("Server (e.g. example.com:8080)", text: $input.server)
                            .urlField()
                        TextField("Username", text: $input.username)
                            .plainField()
                        SecureField("Password", text: $input.password)
                    }
                case .m3u:
                    Section("Playlist") {
                        TextField("Playlist URL", text: $input.m3uURL)
                            .urlField()
                        TextField("EPG URL (optional)", text: $input.epgURL)
                            .urlField()
                    }
                }
                Section {
                    Button("Save") { save() }
                        .disabled(!input.isValid)
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .navigationTitle("Add Playlist")
        }
    }

    private func save() {
        guard let secret = input.secret else { return }
        let name = input.trimmedName
        dismiss()
        Task { await model.addPlaylist(name: name, secret: secret) }
    }
}

private extension View {
    func plainField() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    func urlField() -> some View {
        plainField()
            .keyboardType(.URL)
            .textContentType(.URL)
    }
}
