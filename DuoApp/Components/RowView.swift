import F1TV
import SwiftUI

/// A titled, horizontally scrolling row of tiles.
struct RowView: View {
    let title: String
    let items: [CatalogItem]
    var style: TileStyle = .wide
    let now: Date

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .heading()
                    .padding(.horizontal)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            TileView(item: item, style: style, now: now)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

/// A row from F1 TV (its title, its items, posters for shows).
struct CatalogRowView: View {
    let row: CatalogRow
    let now: Date

    var body: some View {
        RowView(title: row.title, items: row.items, style: row.posters ? .poster : .wide, now: now)
    }
}
