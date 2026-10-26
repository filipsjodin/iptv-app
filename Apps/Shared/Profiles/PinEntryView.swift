import Personal
import SwiftUI

/// Frågar efter PIN för en profil som har en. Rätt kod väljer profilen och stänger vyn.
struct PinEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profile: Profile

    @State private var pin = ""
    @State private var wrong = false
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProfileAvatarLabel(profile: profile)
                        .frame(maxWidth: .infinity)
                }
                Section {
                    SecureField("PIN", text: $pin)
                        .pinKeyboard()
                        .onSubmit(submit)
                        .onChange(of: pin) { _, value in
                            wrong = false
                            let digits = String(value.filter(\.isASCIIDigit).prefix(4))
                            if digits != value { pin = digits }
                            #if os(iOS)
                            if digits.count == 4 { submit() }
                            #endif
                        }
                    Button("OK", action: submit)
                        .disabled(pin.count != 4 || checking)
                } footer: {
                    if wrong {
                        Text("Wrong PIN.").foregroundStyle(.red)
                    } else {
                        Text("Enter the 4-digit PIN.")
                    }
                }
            }
            .navigationTitle(Text(verbatim: profile.name))
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
                try await model.select(profile: profile, pin: code)
                dismiss()
            } catch {
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
