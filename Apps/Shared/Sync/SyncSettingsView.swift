import SwiftUI

/// iCloud-sektionen i Inställningar (iOS och tvOS). Visas aldrig för barnprofiler. I standardbygget (ingen synk)
/// är den en enda stilla rad: en avstängd omkopplare med förklaring, utan något arbete bakom.
struct SyncSettingsView: View {
    @State private var state: SyncSettingsModel

    init(app: AppModel) {
        // Modellen är billig och utan bieffekter; bara den första instansen behålls av `State`.
        _state = State(initialValue: SyncSettingsModel(app: app))
    }

    var body: some View {
        Group {
            if state.isVisible {
                iCloudSection
                if state.showsKeychainControls {
                    keychainSection
                }
            }
        }
        .onAppear { state.refresh() }
    }

    private var iCloudSection: some View {
        Section {
            Toggle("Sync with iCloud", isOn: syncBinding)
                .disabled(!state.syncToggleEnabled)
            if state.isAvailable {
                if let status = state.statusText {
                    Text(verbatim: status).foregroundStyle(.secondary)
                }
                Button("Sync now") { Task { await state.syncNow() } }
                    .disabled(!state.canSyncNow)
            }
        } header: {
            Text(verbatim: "iCloud")
        } footer: {
            if let explanation = state.unavailableExplanation {
                Text(verbatim: explanation)
            } else {
                Text("Synced: profiles, watch history, My List, ratings, settings and subtitle offsets. Not synced: downloads, subtitle files and the OpenSubtitles login. PIN codes only follow if you turn on iCloud Keychain below.")
            }
        }
    }

    private var keychainSection: some View {
        Section {
            Toggle("Sync sign-ins via iCloud Keychain", isOn: keychainBinding)
                .disabled(!state.keychainToggleEnabled)
                .confirmationDialog("Remove from iCloud too?", isPresented: askingBinding,
                                    titleVisibility: .visible) {
                    Button("Keep in iCloud") { Task { await state.confirmKeychainOff(deleteCloudCopy: false) } }
                    Button("Remove from iCloud", role: .destructive) {
                        Task { await state.confirmKeychainOff(deleteCloudCopy: true) }
                    }
                    Button("Cancel", role: .cancel) { state.cancelKeychainOff() }
                } message: {
                    Text("Keep leaves them in iCloud for your other devices. Remove deletes the sign-ins from all your devices.")
                }
            if let error = state.errorMessage {
                Text(verbatim: error).foregroundStyle(.red)
            }
        } footer: {
            Text("Sign-ins include passwords. They are stored in iCloud Keychain, which must be turned on in the system settings.")
        }
    }

    private var syncBinding: Binding<Bool> {
        Binding(get: { state.isSyncOn }, set: { on in Task { await state.setSyncEnabled(on) } })
    }

    private var keychainBinding: Binding<Bool> {
        Binding(get: { state.keychainOn }, set: { on in Task { await state.requestKeychain(on) } })
    }

    private var askingBinding: Binding<Bool> {
        Binding(get: { state.isAskingAboutCloudCopy }, set: { if !$0 { state.keychainQuestionDismissed() } })
    }
}
