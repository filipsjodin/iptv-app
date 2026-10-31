import Foundation
import Subtitles
import SwiftUI

/// Sökbladet "Sök fler undertexter…": träfflista med språk, release, betyg, nedladdningar och märkning av
/// hörselhjälp och AI-översatt, samt återstående dagskvot. Sökningen körs i bladets `.task` och avbryts därför
/// när bladet stängs. Inga serversvar visas, bara fasta texter.
///
/// tvOS: ett vanligt blad med knappar (Select aktiverar en rad och stoppar inte spelaren); Menu/tillbaka
/// (`.onExitCommand`) stänger bara bladet. iOS: ett vanligt blad med Stäng-knapp.
struct SubtitleSearchSheet: View {
    let model: SubtitleSearchModel
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                content
                #if os(tvOS)
                Section {
                    Button("Close", action: onClose)
                }
                #endif
            }
            .navigationTitle(Text("Search subtitles"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
            #endif
        }
        .task { await model.search() }
        .onDisappear { model.cancel() }
        #if os(tvOS)
        .onExitCommand(perform: onClose)
        #endif
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .searching:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching…")
                }
            }
        case .results(let results):
            resultsSection(results, downloading: nil)
        case .downloading(let id):
            resultsSection(model.knownResults, downloading: id)
        case .empty:
            Section { Text("No subtitles found.") }
        case .loginRequired:
            Section {
                Text("Log in to OpenSubtitles in Settings to download subtitles.")
            }
        case .failed(let failure):
            Section {
                Text(Self.message(for: failure))
                if case .quota(let resetAt?) = failure {
                    Text("Resets \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
                // Manuell ny sökning; aldrig automatiskt omförsök.
                Button("Try again") {
                    model.backToResults()
                    if case .failed = model.phase { model.retry() }
                }
            }
        }
    }

    private func resultsSection(_ results: [OpenSubtitlesResult], downloading: Int?) -> some View {
        Section {
            ForEach(results) { result in
                Button {
                    Task { await model.download(result) }
                } label: {
                    SubtitleResultRow(result: result, isDownloading: downloading == result.id)
                }
                .disabled(downloading != nil)
            }
        } footer: {
            if let text = quotaText { Text(verbatim: text) }
        }
    }

    private var quotaText: String? {
        guard let remaining = model.quota?.remaining else { return nil }
        if let allowed = model.quota?.allowed {
            return String(localized: "Downloads left today: \(remaining) of \(allowed)")
        }
        return String(localized: "Downloads left today: \(remaining)")
    }

    /// Fast, lokaliserad text per fel; aldrig serverns eget meddelande.
    static func message(for failure: SubtitleSearchModel.SubtitleSearchFailure) -> LocalizedStringKey {
        switch failure {
        case .noKey: return "Subtitle search is turned off."
        case .notAllowed: return "Subtitle search is not available for this profile."
        case .quota: return "The daily download limit has been reached."
        case .rateLimited: return "Too many requests. Try again in a moment."
        case .network: return "Could not reach OpenSubtitles. Check your connection."
        }
    }
}

private struct SubtitleResultRow: View {
    let result: OpenSubtitlesResult
    let isDownloading: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: languageName)
                    .font(.headline)
                Text(verbatim: result.release)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Label(result.rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star")
                    Label(result.downloadCount.formatted(), systemImage: "arrow.down.circle")
                    if result.hearingImpaired {
                        Label("Hearing impaired", systemImage: "ear")
                    }
                    if result.aiTranslated {
                        Label("AI-translated", systemImage: "sparkles")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isDownloading { ProgressView() }
        }
        .accessibilityElement(children: .combine)
    }

    private var languageName: String {
        Locale.current.localizedString(forLanguageCode: result.language)?.capitalized(with: .current)
            ?? result.language.uppercased()
    }
}
