import SwiftUI

/// Space kept for a later beta, drawn and labelled wherever it shows (owner's rule): today only
/// laptop posture's lower half with one feed. A dashed outline with a caption; not interactive.
struct ReservedArea: View {
    static let caption = "Saved for beta.3: timing tower + track map"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.textTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            Text(Self.caption)
                .font(.subheadline)
                .fontWidth(.condensed)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(16)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
