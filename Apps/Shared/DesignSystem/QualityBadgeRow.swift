import Core
import SwiftUI

/// Kvalitetsmärkena (4K, HDR, Dolby Vision, Atmos, 5.1) som små kapslar i en rad. Tom lista ger ingen vy.
struct QualityBadgeRow: View {
    let badges: [QualityBadge]

    var body: some View {
        if !badges.isEmpty {
            HStack(spacing: 8) {
                ForEach(badges, id: \.self) { badge in
                    Text(verbatim: badge.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(.secondary, lineWidth: 1))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: badges.map(\.rawValue).joined(separator: ", ")))
        }
    }
}
