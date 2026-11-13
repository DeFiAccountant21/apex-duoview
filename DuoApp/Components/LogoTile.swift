import SwiftUI

/// The app icon as a tile: the icon's own rounded corners, a hairline edge so it sits cleanly
/// on the dark background, and a faint red glow taken from the icon's racing line.
struct LogoTile: View {
    var size: CGFloat
    var glow = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        Image("Logo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .shadow(color: glow ? Theme.accent.opacity(0.28) : .clear, radius: size * 0.18)
            .accessibilityHidden(true)
    }
}
