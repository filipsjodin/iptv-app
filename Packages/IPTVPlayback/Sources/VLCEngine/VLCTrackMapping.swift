import Foundation
import PlaybackCore

/// Ren mappning från VLC:s spårbeskrivningar (index + namn) till `MediaTrack`.
///
/// VLC ger bara ett namn per spår, t.ex. `"Track 1 - [Swedish]"`, `"English (E-AC3 5.1) - Atmos"` eller `"sv"`.
/// Språk, kanalantal, Atmos och forced tolkas ur namnet. Index −1 ("Disable") hoppas över.
public enum VLCTrackMapping {
    public static func tracks(from descriptions: [(index: Int32, name: String)], kind: TrackKind) -> [MediaTrack] {
        descriptions.compactMap { description in
            guard description.index >= 0 else { return nil }
            let name = description.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            let isAudio = kind == .audio
            return MediaTrack(
                id: "\(description.index)",
                kind: kind,
                languageCode: language(in: name),
                title: name,
                codec: nil,
                channelCount: isAudio ? channelCount(in: lower) : nil,
                isAtmos: isAudio && (lower.contains("atmos") || containsWord("joc", in: lower)),
                isDefault: false,
                isForced: kind == .subtitle && lower.contains("forced"))
        }
    }

    /// Språk ur hakparenteser (`[Swedish]`, `[eng]`), ur hela namnet (`"sv"`) eller ur ett inledande
    /// språknamn (`"English (E-AC3 5.1)"`). Korta ord (≤ 3 tecken) godtas bara som hela namnet,
    /// så att t.ex. "DTS 5.1" inte tolkas som språkkoden "dts".
    static func language(in name: String) -> String? {
        for bracketed in bracketContents(in: name).reversed() {
            if let code = LanguageCode.normalize(bracketed) { return code }
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 3, !trimmed.contains(" "), let code = LanguageCode.normalize(trimmed) { return code }
        let firstWord = trimmed.prefix { $0.isLetter }
        if firstWord.count > 3, let code = LanguageCode.normalize(String(firstWord)) { return code }
        return nil
    }

    /// "5.1" → 6, "7.1" → 8, "2.0"/"stereo" → 2, "1.0"/"mono" → 1.
    static func channelCount(in lowercasedName: String) -> Int? {
        if let match = lowercasedName.firstMatch(of: /(?:^|[^\d.])(\d)\.(\d)(?!\d)/),
           let main = Int(match.output.1), let lfe = Int(match.output.2), main + lfe > 0 {
            return main + lfe
        }
        if containsWord("stereo", in: lowercasedName) { return 2 }
        if containsWord("mono", in: lowercasedName) { return 1 }
        return nil
    }

    private static func bracketContents(in name: String) -> [String] {
        name.matches(of: /\[([^\[\]]+)\]/).map { String($0.output.1).trimmingCharacters(in: .whitespaces) }
    }

    private static func containsWord(_ word: String, in lowercasedName: String) -> Bool {
        lowercasedName.split { !$0.isLetter }.contains { $0 == word }
    }
}
