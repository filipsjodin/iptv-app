import Playback
import PlaybackCore
import Providers
import SwiftUI
import UIKit

/// Ett val i en spelarmeny.
struct PlayerMenuOption: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let isSelected: Bool
    let action: (@MainActor @Sendable () -> Void)?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.title == b.title && a.isSelected == b.isSelected }
}

/// En av menyerna: Ljud, Undertexter, Kvalitet (bara live med flera varianter), Spelare och Info.
struct PlayerMenu: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let options: [PlayerMenuOption]
}

extension PlayerScreenModel {
    var menus: [PlayerMenu] {
        _ = tickCount
        return [audioMenu, subtitleMenu, qualityMenu, engineMenu, infoMenu].compactMap { $0 }
    }

    /// Kanalens varianter, bäst först, med den spelande markerad. Bara för live med minst två varianter.
    private var qualityMenu: PlayerMenu? {
        let variants = liveVariants
        guard variants.count >= 2 else { return nil }
        // Åtgärden går via modellen (som övriga menyer), så att den alltid träffar aktuell session.
        let options = variants.map { variant in
            let id = variant.id
            return PlayerMenuOption(id: "quality.\(id)", title: variant.name, isSelected: variant.isCurrent,
                                    action: { [weak self] in
                                        guard let self else { return }
                                        Task { await self.selectVariant(id) }
                                    })
        }
        return PlayerMenu(id: "quality", title: String(localized: "Quality"), systemImage: "slider.horizontal.3",
                          options: options)
    }

    private var audioMenu: PlayerMenu {
        // Åtgärderna går via modellen så att de alltid träffar aktuell session (menyerna kan överleva ett
        // avsnittsbyte eftersom `PlayerMenuOption` jämförs utan åtgärden).
        let engine = session.engine
        let options = (engine?.audioTracks ?? []).enumerated().map { index, track in
            let id = track.id
            return PlayerMenuOption(id: "audio.\(id)", title: Self.label(for: track, index: index),
                                    isSelected: engine?.selectedAudioID == id,
                                    action: { [weak self] in self?.session.selectAudio(id) })
        }
        return PlayerMenu(id: "audio", title: String(localized: "Audio"), systemImage: "speaker.wave.2",
                          options: options)
    }

    private var subtitleMenu: PlayerMenu {
        // Åtgärderna går via modellen så att de alltid träffar aktuell session (menyerna kan överleva ett
        // avsnittsbyte eftersom `PlayerMenuOption` jämförs utan åtgärden).
        let engine = session.engine
        var options = [PlayerMenuOption(id: "subtitle.off", title: String(localized: "Off"),
                                        isSelected: engine?.selectedSubtitleID == nil,
                                        action: { [weak self] in self?.session.selectSubtitle(nil) })]
        for (index, track) in (engine?.subtitleTracks ?? []).enumerated() {
            let id = track.id
            options.append(PlayerMenuOption(id: "subtitle.\(id)", title: Self.label(for: track, index: index),
                                            isSelected: engine?.selectedSubtitleID == id,
                                            action: { [weak self] in self?.session.selectSubtitle(id) }))
        }
        options.append(contentsOf: externalSubtitleOptions)
        return PlayerMenu(id: "subtitle", title: String(localized: "Subtitles"), systemImage: "captions.bubble",
                          options: options)
    }

    /// "Sök fler undertexter…" (bara när funktionen är tillgänglig: nyckel finns och inte barnläge) och, när en extern
    /// text är vald, synkjustering. Tecknen är användarens: "+" fördröjer texten (den visas senare), "−" visar den
    /// tidigare. Motorns förskjutning har motsatt tecken, vilket `adjustSubtitleDelay` sköter.
    private var externalSubtitleOptions: [PlayerMenuOption] {
        guard subtitleSearchAvailable else { return [] }
        var options = [PlayerMenuOption(id: "subtitle.search", title: String(localized: "Search more subtitles…"),
                                        isSelected: false,
                                        action: { [weak self] in self?.presentSubtitleSearch() })]
        if externalSubtitleSelected {
            let step = Self.subtitleSyncStep
            options.append(PlayerMenuOption(id: "subtitle.sync.value",
                                            title: String(localized: "Sync: \(Self.delayText(subtitleDelay))"),
                                            isSelected: false, action: nil))
            options.append(PlayerMenuOption(id: "subtitle.sync.earlier",
                                            title: String(localized: "Sync −0.1 s (earlier)"), isSelected: false,
                                            action: { [weak self] in
                                                guard let self else { return }
                                                Task { await self.adjustSubtitleDelay(by: -step) }
                                            }))
            options.append(PlayerMenuOption(id: "subtitle.sync.later",
                                            title: String(localized: "Sync +0.1 s (later)"), isSelected: false,
                                            action: { [weak self] in
                                                guard let self else { return }
                                                Task { await self.adjustSubtitleDelay(by: step) }
                                            }))
            options.append(PlayerMenuOption(id: "subtitle.sync.reset", title: String(localized: "Reset sync"),
                                            isSelected: false,
                                            action: { [weak self] in
                                                guard let self else { return }
                                                Task { await self.resetSubtitleOffset() }
                                            }))
        }
        return options
    }

    /// Ett steg i synkmenyn (sekunder).
    static let subtitleSyncStep = 0.1

    /// "+0,3 s", "−1,2 s" eller "0,0 s" i användarens riktning (positivt = senare).
    static func delayText(_ delay: Double) -> String {
        let value = delay.formatted(.number.precision(.fractionLength(1))
            .sign(strategy: delay == 0 ? .automatic : .always()))
        return String(localized: "\(value) s")
    }

    private var engineMenu: PlayerMenu {
        let current = session.engine?.kind
        let options = [EngineKind.avPlayer, .vlc].map { kind in
            PlayerMenuOption(id: "engine.\(kind.rawValue)", title: kind.displayName, isSelected: current == kind,
                             action: { [weak self] in
                                 guard let self else { return }
                                 Task { await self.switchEngine(to: kind) }
                             })
        }
        return PlayerMenu(id: "engine", title: String(localized: "Player"), systemImage: "play.rectangle",
                          options: options)
    }

    private var infoMenu: PlayerMenu {
        let options = infoLines.enumerated().map { index, line in
            PlayerMenuOption(id: "info.\(index)", title: line, isSelected: false, action: nil)
        }
        return PlayerMenu(id: "info", title: String(localized: "Info"), systemImage: "info.circle", options: options)
    }

    /// Spårets titel, annars språknamnet, annars "Spår N".
    static func label(for track: MediaTrack, index: Int) -> String {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let code = track.languageCode, let name = Locale.current.localizedString(forLanguageCode: code) {
            return name.capitalized(with: .current)
        }
        return String(localized: "Track \(index + 1)")
    }
}

extension VariantQuality {
    /// "4K HDR", "Full HD", "HD", "SD"; variantens eget namn när kvaliteten är okänd.
    func displayName(fallback: String) -> String {
        let base: String
        switch quality {
        case .uhd: base = String(localized: "4K")
        case .fhd: base = String(localized: "Full HD")
        case .hd: base = String(localized: "HD")
        case .sd: base = String(localized: "SD")
        case .unknown: return fallback
        }
        return isHDR ? String(localized: "\(base) HDR") : base
    }
}

/// SwiftUI-menyerna (VLC-overlayen och iOS-menyknappen).
struct PlayerMenuContent: View {
    let menu: PlayerMenu

    var body: some View {
        ForEach(menu.options) { option in
            if let action = option.action {
                Button(action: action) {
                    if option.isSelected {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: option.title)
                    }
                }
            } else {
                Text(verbatim: option.title)
            }
        }
    }
}

/// De fyra menyerna som separata knappar.
struct PlayerMenuButtons: View {
    let model: PlayerScreenModel

    var body: some View {
        HStack {
            ForEach(model.menus) { menu in
                Menu {
                    PlayerMenuContent(menu: menu)
                } label: {
                    Label(menu.title, systemImage: menu.systemImage)
                }
            }
        }
    }
}

/// De fyra menyerna samlade bakom en knapp (iOS ovanpå Apples spelare).
struct PlayerOptionsMenu: View {
    let model: PlayerScreenModel

    var body: some View {
        Menu {
            ForEach(model.menus) { menu in
                Menu {
                    PlayerMenuContent(menu: menu)
                } label: {
                    Label(menu.title, systemImage: menu.systemImage)
                }
            }
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
    }
}

/// UIKit-menyer till `AVPlayerViewController.transportBarCustomMenuItems` (tvOS).
enum PlayerUIMenus {
    @MainActor
    static func make(_ menus: [PlayerMenu]) -> [UIMenuElement] {
        menus.map { menu in
            UIMenu(title: menu.title, image: UIImage(systemName: menu.systemImage),
                   children: menu.options.map { option in
                       let action = option.action
                       return UIAction(title: option.title,
                                       attributes: action == nil ? [.disabled] : [],
                                       state: option.isSelected ? .on : .off) { _ in
                           MainActor.assumeIsolated { action?() }
                       }
                   })
        }
    }
}
