import Personal
import SwiftUI

/// Skapa eller ändra en profil: namn, avatar, barnprofil och (frivilligt) PIN. Standard är ingen PIN; PIN sätts
/// bara om "Kräv PIN" slås på, och kan tas bort genom att slå av den.
struct ProfileEditorView: View {
    enum Mode {
        case add(playlistID: UUID)
        case edit(Profile)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode

    @State private var name: String
    @State private var avatar: String
    @State private var isKids: Bool
    @State private var requirePin: Bool
    /// Ny PIN. Vid ändring av en profil som redan har PIN betyder tomt fält "behåll".
    @State private var pin = ""
    @State private var failed = false
    @State private var confirmingDelete = false

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _avatar = State(initialValue: ProfileAvatars.all[0])
            _isKids = State(initialValue: false)
            _requirePin = State(initialValue: false)
        case let .edit(profile):
            _name = State(initialValue: profile.name)
            _avatar = State(initialValue: profile.avatar)
            _isKids = State(initialValue: profile.isKids)
            _requirePin = State(initialValue: profile.hasPin)
        }
    }

    private var existing: Profile? {
        if case let .edit(profile) = mode { return profile }
        return nil
    }

    private var playlistID: UUID {
        switch mode {
        case let .add(id): id
        case let .edit(profile): profile.playlistID
        }
    }

    /// PIN-ändringen som sparas, eller nil om fälten inte är giltiga.
    private var pinChange: PinChange? {
        guard requirePin else { return existing?.hasPin == true ? .remove : .keep }
        if pin.isEmpty, existing?.hasPin == true { return .keep }
        return isValidPin(pin) ? .set(pin) : nil
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pinChange != nil
    }

    #if os(tvOS)
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 24)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 12)]
    #endif

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
            }
            Section("Avatar") {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(ProfileAvatars.all, id: \.self) { symbol in
                        Button { avatar = symbol } label: {
                            Image(systemName: symbol)
                                .font(.title)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(symbol == avatar ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityAddTraits(symbol == avatar ? .isSelected : [])
                    }
                }
            }
            Section {
                Toggle("Kids profile", isOn: $isKids)
            } footer: {
                Text("Kids profiles only show titles with a known age rating, and no live TV.")
            }
            Section {
                Toggle("Require PIN", isOn: $requirePin)
                if requirePin {
                    Group {
                        if existing?.hasPin == true {
                            SecureField("New PIN (optional)", text: $pin)
                        } else {
                            SecureField("PIN (4 digits)", text: $pin)
                        }
                    }
                    .pinKeyboard()
                    .onChange(of: pin) { _, value in
                        let digits = String(value.filter(\.isASCIIDigit).prefix(4))
                        if digits != value { pin = digits }
                    }
                }
            } footer: {
                Text("Without a PIN the profile is selected directly.")
            }
            Section {
                Button("Save", action: save).disabled(!canSave)
                if failed {
                    Text("The profile could not be saved.").foregroundStyle(.red)
                }
            }
            if let existing {
                Section {
                    Button("Delete Profile", role: .destructive) { confirmingDelete = true }
                        .disabled(model.profiles(for: existing.playlistID).count <= 1)
                }
            }
        }
        .navigationTitle(existing == nil ? Text("New Profile") : Text("Edit Profile"))
        .confirmationDialog("Delete this profile?", isPresented: $confirmingDelete) {
            Button("Delete Profile", role: .destructive) {
                if let existing { model.deleteProfile(existing) }
                dismiss()
            }
        } message: {
            Text("Watch progress, My List and settings for the profile are removed.")
        }
    }

    private func save() {
        guard let change = pinChange else { return }
        do {
            if var profile = existing {
                profile.name = name
                profile.avatar = avatar
                profile.isKids = isKids
                try model.updateProfile(profile, pin: change)
            } else {
                var newPin: String?
                if case let .set(code) = change { newPin = code }
                try model.addProfile(playlistID: playlistID, name: name, avatar: avatar, isKids: isKids, pin: newPin)
            }
            dismiss()
        } catch {
            failed = true
        }
    }
}
