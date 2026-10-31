#if !os(tvOS)
import Observation
import Providers
import SwiftUI

/// En sektion i kanalbytaren.
struct ChannelSwitcherSection: Identifiable {
    let id: String
    let title: String
    let groups: [ChannelGroup]
}

/// Kanalbytarens tillstånd: Favoriter, Senast sedda och alla kanaler, med samma grupper och ordning som zapplistan
/// (favoriter och "alla" i zapplistans ordning, Senast sedda nyast först). Ren data; inget läses i `body` och inget
/// nås utanför minnet. Valet går via `select`, som spelaren kopplar till samma väg som svepzappningen.
@MainActor @Observable
final class ChannelSwitcherModel {
    let sections: [ChannelSwitcherSection]
    let currentID: String

    @ObservationIgnored private let select: @MainActor (ChannelGroup) -> Void

    /// - Parameters:
    ///   - groups: zapplistan i användarens ordning.
    ///   - currentID: grupp-id för kanalen som spelas nu.
    ///   - favoriteIDs: profilens favoriter; okända id:n hoppas över.
    ///   - recentIDs: senast sedda, nyast först; okända id:n hoppas över.
    ///   - select: byter kanal.
    init(groups: [ChannelGroup], currentID: String, favoriteIDs: Set<String> = [], recentIDs: [String] = [],
         select: @escaping @MainActor (ChannelGroup) -> Void) {
        self.currentID = currentID
        self.select = select
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var built: [ChannelSwitcherSection] = []
        let favorites = groups.filter { favoriteIDs.contains($0.id) }
        if !favorites.isEmpty {
            built.append(ChannelSwitcherSection(id: "favorites", title: String(localized: "Favorites"),
                                                groups: favorites))
        }
        var seen: Set<String> = []
        let recents = recentIDs.compactMap { id in seen.insert(id).inserted ? byID[id] : nil }
        if !recents.isEmpty {
            built.append(ChannelSwitcherSection(id: "recents", title: String(localized: "Recently watched"),
                                                groups: recents))
        }
        if !groups.isEmpty {
            built.append(ChannelSwitcherSection(id: "all", title: String(localized: "All channels"), groups: groups))
        }
        sections = built
    }

    /// Byter till kanalen. Den som redan spelas ignoreras; annars anropas `select` en gång.
    func choose(_ group: ChannelGroup) {
        guard group.id != currentID else { return }
        select(group)
    }

    /// Haptik bara vid riktigt kanalbyte; inte när kontrollern skapas (nil → startkanal) eller rensas.
    static func shouldPlayHaptic(old: String?, new: String?) -> Bool {
        guard let old, let new else { return false }
        return old != new
    }

    /// Kanalbytaren finns bara för live med zapplista (minst två kanaler, startkanalen med) och utanför barnläge.
    static func isAvailable(isLive: Bool, kidsRestricted: Bool, zap: LiveZapContext?) -> Bool {
        guard isLive, !kidsRestricted, let zap else { return false }
        return zap.groups.count > 1 && zap.groups.contains { $0.id == zap.start }
    }
}

/// Bladet "Kanaler" i spelaren: kanallistan i sektioner; ett tryck byter kanal och stänger bladet.
struct ChannelSwitcherSheet: View {
    let model: ChannelSwitcherModel
    let onClose: () -> Void

    private static let logoSize = CGSize(width: 56, height: 36)

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.sections) { section in
                    Section(section.title) {
                        ForEach(section.groups, id: \.id) { group in
                            row(group)
                        }
                    }
                }
            }
            .navigationTitle("Channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ group: ChannelGroup) -> some View {
        let isCurrent = group.id == model.currentID
        return Button {
            model.choose(group)
            onClose()
        } label: {
            HStack(spacing: 16) {
                ChannelLogoView(group: group, size: Self.logoSize)
                Text(verbatim: group.displayName).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
#endif
