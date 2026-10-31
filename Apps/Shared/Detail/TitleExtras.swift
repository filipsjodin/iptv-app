import Core
import Library
import Personal
import SwiftUI

/// "Min lista" och 👍/👎 för den aktiva profilen (`PersonalStore`). Samma betyg igen tar bort betyget.
struct PersonalButtons: View {
    @Environment(AppModel.self) private var model
    let ref: ItemRef

    var body: some View {
        let inList = model.isInMyList(ref)
        let rating = model.rating(ref)
        HStack(spacing: 12) {
            Button {
                model.toggleMyList(ref)
            } label: {
                if inList {
                    Label("Remove from My List", systemImage: "checkmark")
                } else {
                    Label("Add to My List", systemImage: "plus")
                }
            }
            Button {
                model.toggleRating(.up, for: ref)
            } label: {
                Label("I like this", systemImage: rating == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .labelStyle(.iconOnly)
            }
            Button {
                model.toggleRating(.down, for: ref)
            } label: {
                Label("I don't like this", systemImage: rating == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.bordered)
    }
}

/// Regissörer och skådespelare som horisontella listor. Ett val visar "Allt med <namn>".
struct PeopleShelves: View {
    let detail: TitleDetail
    let playlistID: UUID

    var body: some View {
        if !detail.directors.isEmpty {
            PeopleShelf(title: Text("Director"), people: detail.directors, playlistID: playlistID)
        }
        if !detail.cast.isEmpty {
            PeopleShelf(title: Text("Cast"), people: detail.cast, playlistID: playlistID)
        }
    }
}

private struct PeopleShelf: View {
    let title: Text
    let people: [PersonCredit]
    let playlistID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title.font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(people) { person in
                        NavigationLink {
                            PersonTitlesView(personID: person.id, name: person.name, playlistID: playlistID)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: person.name).lineLimit(1)
                                if let role = person.role, !role.isEmpty {
                                    Text(verbatim: role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(width: Self.width, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, TitleShelf.focusPadding)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    #if os(tvOS)
    static let width: CGFloat = 260
    #else
    static let width: CGFloat = 140
    #endif
}
