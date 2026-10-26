import Personal
import SwiftUI

/// "Vem tittar?": spellistans profiler. En profil utan PIN väljs direkt; en profil med PIN frågar efter koden.
struct WhoIsWatchingView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID

    @State private var pinFor: Profile?
    @State private var addingProfile = false

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
                            ProfileAvatarLabel(profile: profile)
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
    }

    private func choose(_ profile: Profile) {
        if profile.hasPin {
            pinFor = profile
        } else {
            // Utan PIN: välj direkt (ingen PIN-fråga).
            Task { try? await model.select(profile: profile, pin: nil) }
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

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: profile.avatar)
                .font(.system(size: Self.iconSize))
                .frame(height: Self.iconSize * 1.2)
            HStack(spacing: 4) {
                Text(verbatim: profile.name).lineLimit(1)
                if profile.hasPin {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .accessibilityLabel(Text("PIN"))
                }
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
