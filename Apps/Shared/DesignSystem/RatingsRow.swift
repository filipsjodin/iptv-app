import SwiftUI

/// Betygen (TMDB, IMDb, Rotten Tomatoes) och eventuell åldersgräns i en rad. Inget att visa ger ingen vy.
struct RatingsRow: View {
    let ratings: [TitleRating]
    var certification: String?

    var body: some View {
        if !ratings.isEmpty || certification != nil {
            HStack(spacing: 16) {
                ForEach(ratings, id: \.source) { rating in
                    Text(verbatim: "\(rating.source) \(rating.value)").bold()
                }
                if let certification {
                    Text("Age rating \(certification)")
                }
            }
            .font(.subheadline)
        }
    }
}
