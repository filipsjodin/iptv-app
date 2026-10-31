import Core
import Foundation
import Observation
import Providers
import SwiftUI

/// Tillstånd för info-overlayn vid zappning: vilken kanal som visas, dess "Nu/Nästa" och om den syns. Visas vid
/// varje byte och döljs efter samma tid som spelarens övriga overlay. "Nu/Nästa" läses i bakgrunden via
/// `loadNowNext` och blockerar aldrig bytet; tills det kommer visas bara loggan och namnet.
@MainActor @Observable
final class ChannelInfoModel {
    private(set) var group: ChannelGroup
    private(set) var nowNext: NowNext?
    private(set) var visible = false

    @ObservationIgnored private let loadNowNext: @MainActor (ChannelGroup) async -> NowNext?
    @ObservationIgnored private let hideDelay: Duration
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(group: ChannelGroup, hideDelay: Duration = PlayerControlsOverlay.hideDelay,
         loadNowNext: @escaping @MainActor (ChannelGroup) async -> NowNext?) {
        self.group = group
        self.hideDelay = hideDelay
        self.loadNowNext = loadNowNext
    }

    func show(_ group: ChannelGroup) {
        if group.id != self.group.id { nowNext = nil }
        self.group = group
        visible = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let value = await self.loadNowNext(group)
            guard !Task.isCancelled, self.group.id == group.id else { return }
            self.nowNext = value
        }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let delay = self?.hideDelay else { return }
            do { try await Task.sleep(for: delay) } catch { return }
            self?.visible = false
        }
    }

    func cancel() {
        hideTask?.cancel()
        loadTask?.cancel()
    }
}

/// Info-rutan vid zappning: logga, kanalnamn, pågående program med förlopp och nästa program.
struct ChannelInfoOverlay: View {
    let model: ChannelInfoModel

    #if os(tvOS)
    private static let logoSize = CGSize(width: 140, height: 84)
    #else
    private static let logoSize = CGSize(width: 72, height: 46)
    #endif

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 20) {
                ChannelLogoView(group: model.group, size: Self.logoSize)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: model.group.displayName).font(.headline).lineLimit(1)
                    if let now = model.nowNext?.now {
                        Text("Now: \(now.title)").font(.subheadline).lineLimit(1)
                        ProgressView(value: ChannelRow.fraction(now, at: Date()))
                            .progressViewStyle(.linear)
                    }
                    if let next = model.nowNext?.next {
                        Text("Next: \(next.title)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .padding()
        }
        .opacity(model.visible ? 1 : 0)
        .animation(.default, value: model.visible)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!model.visible)
    }
}
