import AVFoundation
import Core
import Providers
import SwiftUI

/// Live-fliken: Favoriter, Senast sedda och kategorier med kanalrader (logga, namn, "Nu: …" och en tunn
/// förloppsstapel). En lista på iOS, fokusbara rader på tvOS. Långt tryck (tvOS) eller kontextmeny (iOS):
/// Favorit och Dela upp variant. En kanal spelas direkt. Alla databasanrop går via `LiveModel`/`AppModel+Live`.
struct LiveTabView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    let reloadKey: Date?

    var body: some View {
        LiveContent(model: model, playlistID: playlistID, reloadKey: reloadKey)
    }
}

private struct LiveContent: View {
    let appModel: AppModel
    let playlistID: UUID
    let reloadKey: Date?
    @State private var live: LiveModel
    @State private var presented: PlayerPresentation?
    /// Raderna som är synliga (radnyckel → grupp-id); en grupp kan visas i flera sektioner.
    @State private var visibleRows: [String: String] = [:]

    init(model: AppModel, playlistID: UUID, reloadKey: Date?) {
        appModel = model
        self.playlistID = playlistID
        self.reloadKey = reloadKey
        _live = State(initialValue: LiveModel(model: model, playlistID: playlistID))
    }

    #if os(tvOS)
    private static let logoSize = CGSize(width: 140, height: 84)
    #else
    private static let logoSize = CGSize(width: 56, height: 36)
    #endif

    var body: some View {
        content
            .playerCover($presented, playlistID: playlistID, onDismiss: { live.rebuildSections() })
            .task(id: reloadKey) { await live.load() }
            .task(id: appModel.epgRevision) {
                guard appModel.epgRevision > 0 else { return }
                await live.epgUpdated()
            }
            // De synliga raderna ändras vid rullning: vänta kort och läs "Nu/Nästa" för dem.
            .task(id: live.visibleIDs) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await live.refreshNowNext(for: live.visibleGroups)
            }
            // Programmen byts under tiden: uppdatera var 60:e sekund så länge fliken visas.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    await live.refreshNowNext(for: live.visibleGroups)
                }
            }
            .onChange(of: visibleRows) { _, rows in live.setVisible(Set(rows.values)) }
    }

    @ViewBuilder private var content: some View {
        if live.loading && live.sections.isEmpty {
            ProgressView()
        } else if live.failed {
            Text("The library could not be read.").foregroundStyle(.secondary)
        } else if live.sections.isEmpty {
            Text("No channels.").foregroundStyle(.secondary)
        } else {
            channelList
        }
    }

    private func rowKey(_ section: LiveModel.Section, _ group: ChannelGroup) -> String {
        "\(section.id)\u{1F}\(group.id)"
    }

    #if os(tvOS)
    private var channelList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(live.sections) { section in
                    Text(verbatim: section.title).font(.title3.bold()).padding(.top, 20)
                    ForEach(section.groups, id: \.id) { group in
                        let key = rowKey(section, group)
                        Button { play(group) } label: { row(group) }
                            .buttonStyle(.card)
                            .contextMenu { menu(for: group) }
                            .onAppear { visibleRows[key] = group.id }
                            .onDisappear { visibleRows[key] = nil }
                    }
                }
            }
            .padding(.horizontal, 80)
        }
    }
    #else
    private var channelList: some View {
        List {
            ForEach(live.sections) { section in
                Section(section.title) {
                    ForEach(section.groups, id: \.id) { group in
                        let key = rowKey(section, group)
                        Button { play(group) } label: { row(group) }
                            .contextMenu { menu(for: group) }
                            .onAppear { visibleRows[key] = group.id }
                            .onDisappear { visibleRows[key] = nil }
                    }
                }
            }
        }
    }
    #endif

    private func row(_ group: ChannelGroup) -> some View {
        ChannelRow(group: group, nowNext: live.nowNext[group.id], isFavorite: live.favoriteIDs.contains(group.id),
                   logoSize: Self.logoSize)
    }

    @ViewBuilder private func menu(for group: ChannelGroup) -> some View {
        let isFavorite = live.favoriteIDs.contains(group.id)
        Button {
            live.toggleFavorite(group)
        } label: {
            Label(isFavorite ? "Remove from favorites" : "Add to favorites",
                  systemImage: isFavorite ? "star.slash" : "star")
        }
        if group.id.contains("\u{1F}split\u{1F}"), let variant = group.variants.first {
            Button("Merge variants", systemImage: "arrow.triangle.merge") {
                Task { await live.split(providerID: variant.providerID, split: false) }
            }
        } else if group.variants.count > 1 {
            Menu("Split variant", systemImage: "arrow.triangle.branch") {
                ForEach(group.variants, id: \.providerID) { variant in
                    Button { Task { await live.split(providerID: variant.providerID, split: true) } } label: {
                        Text(verbatim: variant.name)
                    }
                }
            }
        }
    }

    /// Bästa varianten för skärmen (HDR bara om enheten kan visa HDR). Ingen nästa-avsnitt-leverantör.
    private func play(_ group: ChannelGroup) {
        guard presented == nil else { return }
        guard let request = appModel.liveRequest(group: group, playlistID: playlistID,
                                                 displaySupportsHDR: AVPlayer.eligibleForHDRPlayback) else { return }
        live.noteWatched(group)
        presented = PlayerPresentation(request: request, nextEpisodeProvider: nil)
    }
}

/// En kanalrad: logga, namn, "Nu: …" och förloppet i det pågående programmet.
private struct ChannelRow: View {
    let group: ChannelGroup
    let nowNext: NowNext?
    let isFavorite: Bool
    let logoSize: CGSize

    var body: some View {
        HStack(spacing: 16) {
            ChannelLogoView(group: group, size: logoSize)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: group.displayName).font(.headline).lineLimit(1)
                    if isFavorite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let current = nowNext?.now {
                    Text("Now: \(current.title)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: Self.fraction(current, at: Date()))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 240)
                } else if let next = nowNext?.next {
                    Text("Next: \(next.title)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Andel av programmet som gått, 0...1.
    static func fraction(_ program: EPGProgram, at date: Date) -> Double {
        let length = program.end.timeIntervalSince(program.start)
        guard length > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(program.start) / length))
    }
}
