import Personal
import SwiftUI

/// Frågar efter PIN för en profil som har en. Rätt kod väljer profilen och stänger vyn. Med `onUnlock` väljs
/// profilen inte; rätt kod skickas i stället till anroparen (t.ex. för att låsa upp profilredigeraren).
/// Med `adultPlaylistID` (och `profile == nil`) frågas efter en vuxen-PIN för spellistans profilhantering.
struct PinEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: Profile?
    var adultPlaylistID: UUID?
    var onUnlock: ((String) -> Void)?

    init(profile: Profile, onUnlock: ((String) -> Void)? = nil) {
        self.profile = profile
        self.onUnlock = onUnlock
    }

    /// Vuxen-PIN för spellistans profilhantering.
    init(adultPinFor playlistID: UUID, onUnlock: @escaping (String) -> Void) {
        profile = nil
        adultPlaylistID = playlistID
        self.onUnlock = onUnlock
    }

    @State private var pin = ""
    @State private var wrong = false
    @State private var lockedOut = false
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                if let profile {
                    Section {
                        ProfileAvatarLabel(profile: profile)
                            .frame(maxWidth: .infinity)
                    }
                }
                Section {
                    SecureField("PIN", text: $pin)
                        .pinKeyboard()
                        .onSubmit(submit)
                        .onChange(of: pin) { _, value in
                            if !value.isEmpty { wrong = false }
                            let digits = String(value.filter(\.isASCIIDigit).prefix(4))
                            if digits != value { pin = digits }
                            #if os(iOS)
                            if digits.count == 4 { submit() }
                            #endif
                        }
                    Button("OK", action: submit)
                        .disabled(pin.count != 4 || checking)
                } footer: {
                    if lockedOut {
                        Text("Too many attempts. Try again in 30 seconds.").foregroundStyle(.red)
                    } else if wrong {
                        Text("Wrong PIN.").foregroundStyle(.red)
                    } else if profile == nil {
                        Text("Enter the PIN of an adult profile to manage profiles.")
                    } else {
                        Text("Enter the 4-digit PIN.")
                    }
                }
            }
            .navigationTitle(profile.map { Text(verbatim: $0.name) } ?? Text("Adult PIN"))
            #if os(iOS)
            // tvOS: Menu-knappen stänger arket.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #endif
        }
    }

    private func submit() {
        guard isValidPin(pin), !checking else { return }
        checking = true
        let code = pin
        Task {
            defer { checking = false }
            do {
                if let adultPlaylistID {
                    try await model.verifyAdultPin(playlistID: adultPlaylistID, pin: code)
                    onUnlock?(code)
                } else if let profile, let onUnlock {
                    try await model.verifyProfilePin(profile, pin: code)
                    onUnlock(code)
                } else if let profile {
                    try await model.select(profile: profile, pin: code)
                }
                dismiss()
            } catch ProfileError.tooManyAttempts {
                lockedOut = true
                wrong = false
                pin = ""
            } catch {
                lockedOut = false
                wrong = true
                pin = ""
            }
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

extension View {
    /// Sifferknappsats där den finns (iOS).
    @ViewBuilder func pinKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
