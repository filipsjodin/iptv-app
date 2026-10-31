#if os(tvOS)
import Core
import Providers
import SwiftUI

/// Kanallistan på tvOS: vänster kolumn med sektionerna från `LiveModel` (fokusbara rader), höger ruta med en liten
/// liveförhandsvisning av den fokuserade kanalen (`ChannelPreview`). Klick/Play på en rad öppnar helskärm via
/// `play`, precis som tidigare.
///
/// Förhandsvisningen följer `PreviewController`: bara kanalen som fokus stannat på startar (settle-fördröjningen
/// ligger i kontrollern), den föregående stängs direkt vid fokusbyte, och allt stoppas synkront när fliken lämnas
/// eller spelaren öppnas. Spelaren stängd igen: fokus ligger kvar och förhandsvisningen startas om för den kanalen.
/// Kontrollern vägrar själv i barnläge och utan aktiv profil.
struct ChannelListView<MenuContent: View>: View {
    let appModel: AppModel
    let live: LiveModel
    let playlistID: UUID
    let logoSize: CGSize
    /// Spelaren visas (helskärm): förhandsvisningen ska vara stoppad.
    let playerPresented: Bool
    @Binding var visibleRows: [String: String]
    let play: (ChannelGroup) -> Void
    @ViewBuilder let menu: (ChannelGroup) -> MenuContent

    @FocusState private var focused: String?
    @State private var previewController: PreviewController?
    /// Kanalen som visas i högra rutan (den senast fokuserade).
    @State private var shownGroup: ChannelGroup?

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            list
            ChannelPreview(group: shownGroup, nowNext: shownGroup.flatMap { live.nowNext[$0.id] },
                           controller: previewController)
                .padding(.top, 20)
        }
        .padding(.horizontal, 80)
        .onAppear {
            if previewController == nil { previewController = appModel.makePreviewController() }
        }
        // Flikbyte: stoppa synkront utan att vänta på stängningen.
        .onDisappear { previewController?.stopNow() }
        .onChange(of: focused) { _, key in handleFocus(key) }
        .onChange(of: playerPresented) { _, presented in
            if presented {
                previewController?.stopNow()
            } else {
                handleFocus(focused)
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(live.sections) { section in
                    Text(verbatim: section.title).font(.title3.bold()).padding(.top, 20)
                    ForEach(section.groups, id: \.id) { group in
                        let key = Self.rowKey(section, group)
                        Button { play(group) } label: {
                            ChannelRow(group: group, nowNext: live.nowNext[group.id],
                                       isFavorite: live.favoriteIDs.contains(group.id), logoSize: logoSize)
                        }
                        .buttonStyle(.card)
                        .focused($focused, equals: key)
                        .contextMenu { menu(group) }
                        .onAppear { visibleRows[key] = group.id }
                        .onDisappear { visibleRows[key] = nil }
                    }
                }
            }
        }
    }

    static func rowKey(_ section: LiveModel.Section, _ group: ChannelGroup) -> String {
        "\(section.id)\u{1F}\(group.id)"
    }

    /// Radnyckeln är `sektion␟grupp-id`; grupp-id:t är allt efter första avskiljaren.
    private func handleFocus(_ key: String?) {
        guard !playerPresented, let key,
              let separator = key.firstIndex(of: "\u{1F}") else {
            // Inget fokus (eller spelaren öppen): ingen förhandsvisning. Ingen databas- eller nätverksåtkomst här.
            previewController?.focusChanged(to: nil, playlistID: playlistID)
            return
        }
        let groupID = String(key[key.index(after: separator)...])
        guard let group = live.groupsByID[groupID] else {
            previewController?.focusChanged(to: nil, playlistID: playlistID)
            return
        }
        shownGroup = group
        previewController?.focus(channel: group, playlistID: playlistID)
    }
}
#endif
