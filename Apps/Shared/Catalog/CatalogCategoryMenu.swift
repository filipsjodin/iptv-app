#if os(tvOS)
import SwiftUI

/// Sidomenyn på Filmer- och Serier-sidorna: en lodrät, rullbar lista med kategorierna. Tillstånd (öppen, vald post)
/// ägs av `CatalogMenuState` i `TVCatalogView`; menyn ritar bara listan och rapporterar vilken post som valts.
struct CatalogCategoryMenu: View {
    let entries: [CatalogMenuEntry]
    @FocusState.Binding var focusedEntry: String?
    let onSelect: (String) -> Void

    /// Menyns bredd.
    static let width: CGFloat = 480

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(entries) { entry in
                    Button { onSelect(entry.id) } label: {
                        Text(verbatim: entry.title)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .focused($focusedEntry, equals: entry.id)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 60)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .focusSection()
    }
}
#endif
