import Core
import Foundation
import Library
import Playback
import PlaybackCore
import Subtitles
import SwiftUI

/// En nedladdad undertext som en rad i info-rutan (texten färdigformaterad utanför `body`).
struct TitleInfoSubtitleRow: Identifiable, Equatable {
    var subtitle: StoredSubtitle
    var text: String
    var id: Int { subtitle.id }
}

/// Det info-rutan visar, färdigformaterat: ljudspår, textspår (inbyggda), nedladdade undertexter, video
/// ("2160p · Dolby Vision · …") och spelare. Rena data utan gränssnitt, så att det testas utan SwiftUI.
struct TitleInfoModel: Equatable {
    var audio: [String]
    var subtitles: [String]
    var downloaded: [StoredSubtitle]
    var video: String?
    var engine: String?

    init(audio: [String] = [], subtitles: [String] = [], downloaded: [StoredSubtitle] = [], video: String? = nil,
         engine: String? = nil) {
        self.audio = audio
        self.subtitles = subtitles
        self.downloaded = downloaded
        self.video = video
        self.engine = engine
    }

    /// Ingenting att visa alls: varken sparade uppgifter eller nedladdade undertexter.
    var isEmpty: Bool { !hasPlaybackInfo && downloaded.isEmpty }

    /// Något har sparats vid uppspelning (annars visas "Visas efter första uppspelningen").
    var hasPlaybackInfo: Bool { !audio.isEmpty || !subtitles.isEmpty || video != nil || engine != nil }

    /// Bygger modellen ur sparad teknisk info och nedladdade undertexter. `languageName` gör en språkkod (t.ex.
    /// "sv") till ett namn; en okänd kod visas som den är.
    static func make(tech: TitleTechInfo?, downloaded: [StoredSubtitle],
                     languageName: (String) -> String = TitleInfoModel.localizedLanguageName) -> TitleInfoModel {
        func names(_ codes: [String]) -> [String] {
            var seen = Set<String>()
            return codes.map(languageName).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        let summary = tech?.videoSummary.flatMap { $0.isEmpty ? nil : $0 }
        let engine = tech?.engine.flatMap { $0.isEmpty ? nil : $0 }
        return TitleInfoModel(audio: names(tech?.audioLanguages ?? []), subtitles: names(tech?.subtitleLanguages ?? []),
                              downloaded: downloaded, video: summary, engine: engine)
    }

    /// Raderna för nedladdade undertexter: "Svenska · Utgåvans namn".
    func downloadedRows(languageName: (String) -> String = TitleInfoModel.localizedLanguageName)
        -> [TitleInfoSubtitleRow] {
        downloaded.map { subtitle in
            let language = languageName(subtitle.language)
            let text = subtitle.release.isEmpty ? language : "\(language) · \(subtitle.release)"
            return TitleInfoSubtitleRow(subtitle: subtitle, text: text)
        }
    }

    /// "sv" blir "Svenska" (på appens språk); okänd kod blir som den är.
    static func localizedLanguageName(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return Locale.current.localizedString(forLanguageCode: trimmed)?.capitalized(with: .current) ?? trimmed
    }
}

/// Info-rutan på detaljsidan: ljudspår, textspår, nedladdade undertexter, video och spelare, samt "Sök undertexter"
/// utan pågående uppspelning. Läser när sidan visas (och efter att spelaren stängts), aldrig i `body`.
/// Barnprofil: ingen ruta, ingen sökknapp och inga externa anrop (`titleInfoContext` ger `nil`).
///
/// Serier: uppgifterna och sökningen gäller senast spelade avsnitt. Nedladdade undertexter tas bort med långt tryck
/// (kontextmeny) och används nästa gång titeln spelas.
struct TitleInfoBox: View {
    @Environment(AppModel.self) private var model
    let kind: ContentKind
    let providerID: String
    let playlistID: UUID
    /// Spelaren visas över sidan; uppgifterna läses om när den stängts.
    let playerActive: Bool

    @State private var loaded: LoadedBox?
    @State private var search: SubtitleSearchModel?

    /// Det som ritas, färdigformaterat vid läsningen.
    private struct LoadedBox {
        var info: TitleInfoModel
        var rows: [TitleInfoSubtitleRow]
        var request: PlaybackRequest?
        var canSearch: Bool
    }

    var body: some View {
        // Nollhög bärare, så att `.task` körs även innan något lästs (en tom vy får inga livscykelanrop).
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 0)
            if let loaded, !model.kidsRestricted {
                content(loaded)
            }
        }
        .task(id: playerActive) {
            guard !playerActive else { return }
            await reload()
        }
        .sheet(isPresented: searchPresented) {
            if let search {
                SubtitleSearchSheet(model: search, onClose: { dismissSearch() })
            }
        }
    }

    private func content(_ box: LoadedBox) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Title Info").font(.title3.bold())
            if box.info.hasPlaybackInfo {
                infoRow("Audio", box.info.audio)
                infoRow("Subtitles", box.info.subtitles)
                if let video = box.info.video { infoRow("Video", [video]) }
                if let engine = box.info.engine { infoRow("Player", [engine]) }
            } else {
                Text("Shown after first playback").foregroundStyle(.secondary)
            }
            if !box.rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloaded subtitles").font(.headline)
                    ForEach(box.rows) { row in
                        downloadedRow(row, request: box.request)
                    }
                }
            }
            if box.canSearch {
                Button { presentSearch(box.request) } label: {
                    Label("Search subtitles", systemImage: "captions.bubble")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func infoRow(_ label: LocalizedStringKey, _ values: [String]) -> some View {
        if !values.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).bold()
                Text(verbatim: values.joined(separator: ", "))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func downloadedRow(_ row: TitleInfoSubtitleRow, request: PlaybackRequest?) -> some View {
        let text = Text(verbatim: row.text).font(.callout).foregroundStyle(.secondary)
        #if os(tvOS)
        text
            .focusable()
            .contextMenu { removeButton(row, request: request) }
        #else
        text
            .contextMenu { removeButton(row, request: request) }
        #endif
    }

    private func removeButton(_ row: TitleInfoSubtitleRow, request: PlaybackRequest?) -> some View {
        Button("Remove", systemImage: "trash", role: .destructive) {
            remove(row.subtitle, request: request)
        }
    }

    // MARK: Läsning

    private func reload() async {
        let context = await model.titleInfoContext(kind: kind, providerID: providerID, playlistID: playlistID)
        guard !Task.isCancelled else { return }
        guard let context else {
            loaded = nil
            return
        }
        loaded = LoadedBox(info: context.info, rows: context.info.downloadedRows(), request: context.request,
                           canSearch: context.request != nil && model.subtitlesAvailable)
    }

    // MARK: Sökning och borttagning

    private var searchPresented: Binding<Bool> {
        Binding(get: { search != nil }, set: { if !$0 { dismissSearch() } })
    }

    private func presentSearch(_ request: PlaybackRequest?) {
        guard let request, search == nil, model.subtitlesAvailable else { return }
        search = SubtitleSearchModel(request: request, playlistID: playlistID, app: model,
                                     preferredLanguages: model.settings.tracks.subtitleLanguages) { _ in
            // Används nästa gång titeln spelas; listan uppdateras och bladet stängs.
            dismissSearch()
            await reload()
        }
    }

    private func dismissSearch() {
        search?.cancel()
        search = nil
    }

    private func remove(_ subtitle: StoredSubtitle, request: PlaybackRequest?) {
        guard let request else { return }
        Task {
            _ = await model.removeStoredSubtitle(subtitle, for: request, playlistID: playlistID)
            await reload()
        }
    }
}
