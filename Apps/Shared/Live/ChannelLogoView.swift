import SwiftUI

/// Kanalens logga via `ArtworkImage`. Saknas logotypen visas en textlogga: initialer på en färg som härleds
/// stabilt ur namnet (samma kanal får alltid samma färg, även mellan körningar).
struct ChannelLogoView: View {
    let group: ChannelGroup
    let size: CGSize

    var body: some View {
        Group {
            if let url = group.logoURL {
                ArtworkImage(url: url, kind: .logo, placeholderSystemImage: "tv")
                    .contentMode(.fit)
                    .padding(size.height * 0.08)
                    .background(.quaternary)
            } else {
                Self.textLogo(name: group.displayName, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: size.height * 0.16, style: .continuous))
        .accessibilityHidden(true)
    }

    private static func textLogo(name: String, size: CGSize) -> some View {
        ZStack {
            Color(hue: Double(hue(for: name)) / 360, saturation: 0.45, brightness: 0.55)
            Text(verbatim: initials(for: name))
                .font(.system(size: size.height * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }

    /// Nyans 0..<360 ur namnet. FNV-1a över UTF-8: `hashValue` slumpas per körning och dög inte.
    nonisolated static func hue(for name: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % 360)
    }

    /// Högst två versaler: första tecknet i de två första orden, eller de två första tecknen i ett ensamt ord.
    nonisolated static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let first = words.first else { return "?" }
        let letters: String
        if words.count > 1 {
            letters = String(first.prefix(1)) + String(words[1].prefix(1))
        } else {
            letters = String(first.prefix(2))
        }
        return letters.uppercased()
    }
}
