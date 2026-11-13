import F1TV
import SwiftUI

enum TileStyle {
    case wide
    case poster
}

/// One tile: a 16:9 picture (or 2:3 poster), a title and a subtitle. A button that opens `route`.
struct TileView: View {
    let title: String
    let subtitle: String
    let picturePath: String?
    let style: TileStyle
    let route: Route
    var progress: Double?
    var dimmed = false

    @Environment(\.horizontalSizeClass) private var sizeClass

    init(
        title: String, subtitle: String, picturePath: String?, style: TileStyle = .wide,
        route: Route, progress: Double? = nil, dimmed: Bool = false
    ) {
        self.title = title
        self.subtitle = subtitle
        self.picturePath = picturePath
        self.style = style
        self.route = route
        self.progress = progress
        self.dimmed = dimmed
    }

    init(item: CatalogItem, style: TileStyle = .wide, now: Date) {
        self.init(
            title: item.title,
            subtitle: item.subtitle(now: now, calendar: .current),
            picturePath: item.picturePath, style: style, route: .forItem(item),
            dimmed: item.isUpcoming(now: now))
    }

    private var width: CGFloat {
        let regular = sizeClass == .regular
        switch style {
        case .wide: return regular ? 300 : 220
        case .poster: return regular ? 170 : 130
        }
    }

    private var height: CGFloat {
        switch style {
        case .wide: return width * 9 / 16
        case .poster: return width * 3 / 2
        }
    }

    private var pictureURL: URL? {
        // About twice the point size, for a sharp picture on a 3x screen without wasting bytes.
        picturePath.map { Endpoints.image(path: $0, width: Int(width * 2), height: Int(height * 2)) }
    }

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 6) {
                picture
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
            .opacity(dimmed ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(dimmed)
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }

    private var picture: some View {
        ZStack(alignment: .bottom) {
            AsyncImage(url: pictureURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: width, height: height)
            .clipped()
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .padding(6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
