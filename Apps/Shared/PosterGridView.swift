#if !os(tvOS)
import Library
import PlaybackCore
import SwiftUI

extension DynamicTypeSize {
    /// Grov skala för `LayoutMetrics`: tillgänglighetsstorlekarna ger en kolumn färre.
    var layoutScale: Double { isAccessibilitySize ? 1.5 : 1 }
}

/// En grupp titlar i gridet, med valfri rubrik (Filmer/Serier i Sök).
struct PosterGridSection: Identifiable {
    let id: String
    var title: LocalizedStringKey?
    let items: [Library.LibraryItem]
}

/// Adaptiv affischgrid (iOS): kolumnantal och affischbredd kommer från `LayoutMetrics` ur den bredd gridet faktiskt
/// får, så Split View, Slide Over och stor Dynamic Type räknas om vid breddändring. Lat grid med stabila id:n
/// (`LibraryItem.id`). `onAppearLast` anropas när den sista titelns cell visas (sidning).
struct PosterGridView<Footer: View>: View {
    let sections: [PosterGridSection]
    let playlistID: UUID
    var onAppearLast: (() -> Void)?
    let footer: Footer

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Bredden som ScrollView:n får, mätt med `onGeometryChange`; 0 tills första mätningen.
    @State private var width = 0.0

    init(sections: [PosterGridSection], playlistID: UUID, onAppearLast: (() -> Void)? = nil,
         @ViewBuilder footer: () -> Footer) {
        self.sections = sections
        self.playlistID = playlistID
        self.onAppearLast = onAppearLast
        self.footer = footer()
    }

    init(items: [Library.LibraryItem], playlistID: UUID, onAppearLast: (() -> Void)? = nil,
         @ViewBuilder footer: () -> Footer) {
        self.init(sections: [PosterGridSection(id: "items", title: nil, items: items)], playlistID: playlistID,
                  onAppearLast: onAppearLast, footer: footer)
    }

    var body: some View {
        let metrics = LayoutMetrics(availableWidth: width, dynamicTypeScale: dynamicTypeSize.layoutScale)
        let posterWidth = CGFloat(metrics.posterWidth)
        let columns = Array(repeating: GridItem(.fixed(posterWidth), spacing: CGFloat(metrics.spacing),
                                                alignment: .top),
                            count: metrics.columns)
        let lastID = sections.last { !$0.items.isEmpty }?.items.last?.id
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(sections) { section in
                    if !section.items.isEmpty {
                        Section {
                            ForEach(section.items) { item in
                                NavigationLink {
                                    TitleDestination(kind: item.kind, providerID: item.providerID,
                                                     playlistID: playlistID, item: item)
                                } label: {
                                    PosterCard(item: item, playlistID: playlistID, width: posterWidth)
                                }
                                .buttonStyle(.plain)
                                .onAppear {
                                    if item.id == lastID { onAppearLast?() }
                                }
                            }
                        } header: {
                            if let title = section.title {
                                Text(title)
                                    .font(.title3.bold())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityAddTraits(.isHeader)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, CGFloat(LayoutMetrics.sideMargin))
            .padding(.vertical, 8)
            footer
                .frame(maxWidth: .infinity)
                .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width = $0 }
    }
}

extension PosterGridView where Footer == EmptyView {
    init(sections: [PosterGridSection], playlistID: UUID, onAppearLast: (() -> Void)? = nil) {
        self.init(sections: sections, playlistID: playlistID, onAppearLast: onAppearLast) { EmptyView() }
    }

    init(items: [Library.LibraryItem], playlistID: UUID, onAppearLast: (() -> Void)? = nil) {
        self.init(sections: [PosterGridSection(id: "items", title: nil, items: items)], playlistID: playlistID,
                  onAppearLast: onAppearLast)
    }
}
#endif
