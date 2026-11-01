import Personal
import SwiftUI

/// "Vem tittar?": spellistans profiler. En profil utan PIN väljs direkt; en profil med PIN frågar efter koden.
struct WhoIsWatchingView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID

    @State private var pinFor: Profile?
    @State private var addingProfile = false
    /// Synkad profil som är PIN-skyddad på en annan enhet: förklaringen visas i stället för att inget händer.
    @State private var showingLockedNotice = false

    #if os(tvOS)
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 48)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 24)]
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Text("Who's watching?")
                    .font(.title2.bold())
                LazyVGrid(columns: columns, spacing: 32) {
                    ForEach(model.profiles(for: playlistID)) { profile in
                        Button { choose(profile) } label: {
                            ProfileAvatarLabel(profile: profile, locked: model.profileNeedsPin(profile.id))
                        }
                        .profileButtonStyle()
                    }
                    Button { addingProfile = true } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: ProfileAvatarLabel.iconSize))
                            Text("Add Profile")
                        }
                    }
                    .profileButtonStyle()
                }
            }
            .padding()
        }
        .sheet(item: $pinFor) { profile in
            PinEntryView(profile: profile)
        }
        .sheet(isPresented: $addingProfile) {
            NavigationStack {
                ProfileEditorView(mode: .add(playlistID: playlistID))
            }
        }
        .alert("Locked profile", isPresented: $showingLockedNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: SyncMissingCredentials.lockedProfile)
        }
    }

    private func choose(_ profile: Profile) {
        if model.profileNeedsPin(profile.id) {
            showingLockedNotice = true
        } else if profile.hasPin {
            pinFor = profile
        } else {
            // Utan PIN: välj direkt (ingen PIN-fråga).
            Task {
                do {
                    try await model.select(profile: profile, pin: nil)
                } catch {
                    // Bara den låsta synkprofilen får en förklaring; övriga fel ignoreras som förut.
                    if SyncMissingCredentials.lockedProfileMessage(for: error) != nil { showingLockedNotice = true }
                }
            }
        }
    }
}

/// Avatar och namn; ett lås visar att profilen har PIN.
struct ProfileAvatarLabel: View {
    #if os(tvOS)
    static let iconSize: CGFloat = 96
    #else
    static let iconSize: CGFloat = 56
    #endif

    let profile: Profile
    /// Synkad profil som kräver PIN på den här enheten (PIN-hashen saknas här): visas som låst.
    var locked = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: profile.avatar)
                .font(.system(size: Self.iconSize))
                .frame(height: Self.iconSize * 1.2)
            HStack(spacing: 4) {
                Text(verbatim: profile.name).lineLimit(1)
                if profile.hasPin || locked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .accessibilityLabel(Text("PIN"))
                }
            }
            if locked {
                Text(verbatim: SyncMissingCredentials.lockedProfileShort).font(.caption).foregroundStyle(.secondary)
            }
            if profile.isKids {
                Text("Kids").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

extension View {
    /// tvOS: kort med fokuseffekt; iOS: ren knapp.
    @ViewBuilder func profileButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
        #endif
    }
}
