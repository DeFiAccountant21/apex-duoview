import Library
import SwiftUI

/// "Pick up where you left off": the last bookmark's title and place, a Resume button and an ×.
struct ResumeBanner: View {
    let bookmark: WatchBookmark
    let onResume: () -> Void
    let onDismiss: () -> Void

    /// A bookmark saved less than this long ago is offered.
    static let maxAge: TimeInterval = 3 * 24 * 60 * 60

    static func isFresh(_ bookmark: WatchBookmark, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(bookmark.savedAt)
        return age >= 0 && age < maxAge
    }

    /// "Live", or "at 1:23:45" (under an hour "at 23:45").
    static func positionText(_ bookmark: WatchBookmark) -> String {
        if bookmark.live { return "Live" }
        let total = Int(max(bookmark.positionMs, 0) / 1_000)
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        let clock = h > 0
            ? "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
            : "\(m):\(String(format: "%02d", s))"
        return "at \(clock)"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(Self.positionText(bookmark)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Resume", action: onResume)
                .buttonStyle(.borderedProminent)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.footnote.weight(.semibold))
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
    }
}
