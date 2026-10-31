import Subtitles
import SwiftUI

/// OpenSubtitles-konto: inloggning (användarnamn och lösenord), återstående dagskvot och utloggning. Uppgifterna
/// hålls bara i de här fälten tills inloggningen lyckats (då sparas de i Keychain av `AppModel`) och rensas
/// direkt efteråt. Dolt för barnprofiler; utan API-nyckel visas att funktionen är avstängd.
struct OpenSubtitlesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var quota: OpenSubtitlesQuota?

    var body: some View {
        Form {
            if model.kidsRestricted {
                EmptyView()
            } else if !model.subtitlesAvailable {
                Section {
                    LabeledContent {
                        Text("Feature is turned off")
                    } label: {
                        Text(verbatim: "OpenSubtitles")
                    }
                } footer: {
                    Text("Add an OpenSubtitles API key to Secrets.xcconfig to turn on subtitle downloads.")
                }
            } else if model.openSubtitlesLoggedIn {
                loggedInSection
            } else {
                loggedOutSection
            }
        }
        .navigationTitle(Text("Subtitle downloads"))
        .task {
            await model.refreshOpenSubtitlesStatus()
            if model.openSubtitlesLoggedIn { quota = await model.openSubtitlesQuota() }
        }
    }

    private var loggedInSection: some View {
        Section {
            LabeledContent {
                Text("Signed in")
            } label: {
                Text(verbatim: "OpenSubtitles")
            }
            if let text = quotaText {
                Text(verbatim: text).foregroundStyle(.secondary)
            }
            Button("Log Out", role: .destructive) { logout() }
            if let errorMessage {
                Text(verbatim: errorMessage).foregroundStyle(.red)
            }
        } header: {
            Text("Account")
        }
    }

    private var loggedOutSection: some View {
        Section {
            TextField("Username", text: $username)
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .textContentType(.username)
            #endif
            SecureField("Password", text: $password)
            #if os(iOS)
                .textContentType(.password)
            #endif
            Button("Log In") { login() }
                .disabled(busy || username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            if busy { ProgressView() }
            if let errorMessage {
                Text(verbatim: errorMessage).foregroundStyle(.red)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Downloading subtitles needs a free OpenSubtitles account. Your login is stored only in the Keychain on this device.")
        }
    }

    private var quotaText: String? {
        guard let remaining = quota?.remaining else { return nil }
        if let allowed = quota?.allowed { return String(localized: "Downloads left today: \(remaining) of \(allowed)") }
        return String(localized: "Downloads left today: \(remaining)")
    }

    private func login() {
        let name = username.trimmingCharacters(in: .whitespaces)
        let secret = password
        busy = true
        errorMessage = nil
        Task {
            do {
                let result = try await model.openSubtitlesLogin(username: name, password: secret)
                quota = result
                username = ""
                password = ""
            } catch {
                errorMessage = Self.message(for: error)
            }
            busy = false
        }
    }

    private func logout() {
        do {
            try model.openSubtitlesLogout()
            quota = nil
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Could not log out.")
        }
    }

    /// Fast, lokaliserad text per fel. Aldrig felets egen beskrivning (kan i princip bära server- eller kontodata).
    static func message(for error: any Error) -> String {
        switch error as? OpenSubtitlesError {
        case .invalidCredentials: return String(localized: "Wrong username or password.")
        case .quotaExhausted: return String(localized: "The daily download limit has been reached.")
        case .rateLimited: return String(localized: "Too many requests. Try again in a moment.")
        case .network: return String(localized: "Could not reach OpenSubtitles. Check your connection.")
        case .noAPIKey: return String(localized: "The key was rejected by OpenSubtitles.")
        case .notLoggedIn, .badResponse, nil: return String(localized: "Could not log in. Try again.")
        }
    }
}
