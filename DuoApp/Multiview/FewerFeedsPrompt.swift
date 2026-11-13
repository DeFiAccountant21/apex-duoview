import Multiview
import SwiftUI

/// The once-only question when the multiview shows fewer than four feeds (a feed removed, a
/// remembered feed missing from this session, or a session with fewer feeds): keep four spots,
/// with "Pick a feed" in the empty ones, or fit the feeds there are to the screen. The answer is
/// stored and never asked again; Settings › Multiview changes it.
struct FewerFeedsPrompt: ViewModifier {
    let controller: MultiviewController
    /// False while something else is presented over the multiview (the feeds editor): the
    /// question waits until it closes.
    let enabled: Bool

    func body(content: Content) -> some View {
        let count = controller.filledCount
        return content.alert(
            "Fewer than four feeds",
            isPresented: Binding(
                get: { enabled && controller.asksFewerFeeds },
                // Closed only by an answer, which ends `asksFewerFeeds` itself.
                set: { _ in })
        ) {
            Button("Keep four spots") { controller.setFewerFeeds(.keepSpots) }
            Button("Fit \(count) to the screen") { controller.setFewerFeeds(.fit) }
        } message: {
            Text("You can change this any time in Settings › Multiview.")
        }
    }
}

extension View {
    func fewerFeedsPrompt(_ controller: MultiviewController, enabled: Bool) -> some View {
        modifier(FewerFeedsPrompt(controller: controller, enabled: enabled))
    }
}
