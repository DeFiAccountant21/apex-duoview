import SwiftUI

/// The app's look: near-black, brushed silver and one racing red, taken from the app icon.
/// Every colour and type rule lives here; views never hard-code them.
/// Nothing in here is main-actor isolated: `Color` is Sendable, and the helpers are plain functions.
enum Theme {
    // MARK: Colours

    static let background = rgb(0x0A, 0x0A, 0x0B)
    static let surface = rgb(0x15, 0x15, 0x17)
    static let raised = rgb(0x1E, 0x1E, 0x21)
    static let hairline = rgb(0x2A, 0x2A, 0x2E)

    static let textPrimary = rgb(0xE9, 0xE9, 0xEC)
    static let textSecondary = rgb(0x9A, 0x9A, 0xA2)
    static let textTertiary = rgb(0x66, 0x66, 0x6D)

    /// Racing red. For the live badge, progress bars, selection, toggles and primary buttons.
    /// Never for small body text (about 4.3:1 on the background).
    static let accent = rgb(0xEC, 0x00, 0x14)

    /// Corner radius of tiles and rows.
    static let cornerRadius: CGFloat = 10

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

// MARK: - Text styles (Dynamic Type text styles only)

extension Text {
    /// Bold, condensed, primary silver. Screen and row headings.
    func heading(_ style: Font.TextStyle = .title3) -> Text {
        font(.system(style)).bold().fontWidth(.condensed).foregroundStyle(Theme.textPrimary)
    }

    /// Bold, condensed row and tile titles.
    func rowTitle(_ style: Font.TextStyle = .body) -> Text {
        font(.system(style)).bold().fontWidth(.condensed).foregroundStyle(Theme.textPrimary)
    }

    /// Small, uppercase, condensed with a little tracking.
    func sectionLabel() -> some View {
        font(.caption).fontWidth(.condensed).tracking(1).foregroundStyle(Theme.textSecondary)
            .textCase(.uppercase)
    }

    /// The red LIVE capsule: white, bold, condensed.
    func liveBadge() -> some View {
        font(.caption).bold().fontWidth(.condensed).foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accent, in: Capsule())
    }
}

// MARK: - Surfaces

extension View {
    /// A surface card with 10 pt continuous corners.
    func card() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        return background(Theme.surface, in: shape).clipShape(shape)
    }

    /// The app background, behind everything (also under the safe areas).
    func themedBackground() -> some View {
        background(Theme.background)
    }
}
