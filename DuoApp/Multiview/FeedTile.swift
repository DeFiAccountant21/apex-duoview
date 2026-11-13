import AVFoundation
import F1TV
import SwiftUI
import UIKit

/// One multiview slot: the feed's picture (aspect-fit, never cropped), its name and the red SOUND
/// badge on the feed with the sound. An empty slot is a dark tile reading "Pick a feed".
/// `MultiviewView` lays the tile's touch surface (`TileTouchSurface`: tap, hold-and-drag, the
/// closed swipe) and then the speaker button (`FeedSpeakerButton`) over it.
/// The tile only shows a player; the controller owns it.
struct FeedTile: View {
    let controller: MultiviewController
    let channel: Channel?
    let slot: Int
    /// False while the layout hides this feed (it plays on, out of sight, under the main tile):
    /// its quality cap is then the default for a non-main feed, not the main tile's size it shares.
    let isVisible: Bool
    /// While the multiview loads, empty tiles stay blank rather than ask for a pick.
    let showsPickPrompt: Bool

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let channel, let id = channel.id {
            feed(channel, id: id)
        } else {
            empty
        }
    }

    private func feed(_ channel: Channel, id: Int) -> some View {
        let hasSound = controller.audioChannelId == id
        let problem = controller.feedProblems[id]
        return ZStack {
            Color.black
            FeedPlayerLayer(controller: controller, channelId: id, player: controller.player(for: id))
            if let problem {
                note(problem)
            } else if controller.isFrozen(channelId: id) {
                note("Paused to keep the main feed smooth")
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Text(channel.displayTitle)
                    .rowTitle(.caption)
                    .lineLimit(1)
                if hasSound {
                    Text("SOUND").liveBadge()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // The tile's size, as beta.1's fold reader measures the root: a GeometryReader whose
        // `onChange` runs on the main actor.
        .background {
            GeometryReader { proxy in
                // `.zero` stands for "hidden" (a shown tile is never that small).
                let size = isVisible ? proxy.size : CGSize.zero
                Color.clear
                    .onChange(of: size, initial: true) { _, newSize in
                        let pixels = newSize == .zero
                            ? MultiviewController.defaultOtherResolution
                            : CGSize(width: newSize.width * displayScale, height: newSize.height * displayScale)
                        controller.setTileSize(pixels, for: id)
                    }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasSound ? "\(channel.displayTitle), sound on" : channel.displayTitle)
        .accessibilityAddTraits(slot == 0 ? AccessibilityTraits() : .isButton)
    }

    private var empty: some View {
        ZStack {
            Theme.surface
            if showsPickPrompt {
                Text("Pick a feed")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // A tap opens the feeds editor on this slot.
        .accessibilityAddTraits(showsPickPrompt ? .isButton : AccessibilityTraits())
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(8)
    }
}

// MARK: - Speaker

/// A feed's speaker: a speaker with waves on the feed with the sound, a crossed-out one on the
/// others; tapping it moves the sound to this feed. A 44 pt hit area around a smaller disc.
/// Its own Button and its own accessibility element.
struct FeedSpeakerButton: View {
    let controller: MultiviewController
    let channelId: Int
    let title: String

    var body: some View {
        let hasSound = controller.audioChannelId == channelId
        Button {
            controller.setAudio(channelId: channelId)
        } label: {
            Image(systemName: hasSound ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.55), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasSound ? "Sound from \(title)" : "Play sound from \(title)")
        .accessibilityAddTraits(hasSound ? .isSelected : AccessibilityTraits())
    }
}

// MARK: - Touch

/// What a hold-and-drag on a tile reports. Points and translations are in window coordinates.
enum TileDragEvent {
    /// Held long enough: the tile lifts.
    case began
    /// The finger moved this far from where the hold began.
    case moved(CGSize)
    /// The finger lifted here.
    case ended(CGPoint)
    /// The system took the touch (or the hold failed): the tile glides back.
    case cancelled
}

/// A clear UIKit view over a tile that carries its touches with UIKit gesture recognizers: a tap,
/// a press held `holdDuration` (10 pt of give) that then drags, and, on the closed layout, a pan
/// for the swipe. SwiftUI's own tap plus a sequenced long-press-and-drag on the same view stopped
/// both from firing in the owner's check, so the tile's touches live here.
///
/// The tap waits for the hold to fail (only while the hold is enabled), so a press that was held
/// never also swaps. The callbacks are swapped in on every update, so they always see the tile's
/// current slot and the current drop targets. UIKit calls the targets on the main thread; the
/// coordinator is main-actor isolated.
struct TileTouchSurface: UIViewRepresentable {
    /// False for a hidden tile: it then lets touches through to the tile under it.
    var isActive: Bool
    var canDrag: Bool
    var canSwipe: Bool
    var holdDuration: TimeInterval
    var onTap: @MainActor () -> Void
    var onDrag: @MainActor (TileDragEvent) -> Void
    /// The pan's whole translation when the finger lifts.
    var onSwipe: @MainActor (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = holdDuration
        hold.allowableMovement = 10
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        // The tap waits for the hold to fail, through the delegate so it only does while the hold
        // is enabled (a tile that can't be dragged answers its tap at once).
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(pan)
        coordinator.tap = tap
        coordinator.hold = hold
        coordinator.pan = pan
        apply(to: view, coordinator)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        apply(to: view, context.coordinator)
    }

    private func apply(to view: UIView, _ coordinator: Coordinator) {
        coordinator.onTap = onTap
        coordinator.onDrag = onDrag
        coordinator.onSwipe = onSwipe
        if view.isUserInteractionEnabled != isActive { view.isUserInteractionEnabled = isActive }
        if coordinator.hold?.isEnabled != canDrag { coordinator.hold?.isEnabled = canDrag }
        if coordinator.pan?.isEnabled != canSwipe { coordinator.pan?.isEnabled = canSwipe }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: @MainActor () -> Void = {}
        var onDrag: @MainActor (TileDragEvent) -> Void = { _ in }
        var onSwipe: @MainActor (CGSize) -> Void = { _ in }
        weak var tap: UITapGestureRecognizer?
        weak var hold: UILongPressGestureRecognizer?
        weak var pan: UIPanGestureRecognizer?
        /// Where the hold began, in window coordinates.
        private var start = CGPoint.zero

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onTap()
        }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            // `location(in: nil)` is in the window's coordinates.
            let point = recognizer.location(in: nil)
            switch recognizer.state {
            case .began:
                start = point
                onDrag(.began)
            case .changed:
                onDrag(.moved(CGSize(width: point.x - start.x, height: point.y - start.y)))
            case .ended:
                onDrag(.ended(point))
            case .cancelled, .failed:
                onDrag(.cancelled)
            default:
                break
            }
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            let translation = recognizer.translation(in: nil)
            onSwipe(CGSize(width: translation.x, height: translation.y))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === tap && otherGestureRecognizer === hold && otherGestureRecognizer.isEnabled
        }
    }
}

// MARK: - Player layer

/// A view whose own layer is the `AVPlayerLayer`, so it resizes with the view.
private final class FeedLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass guarantees the type.
        layer as! AVPlayerLayer
    }
}

/// The feed's picture. Its layer is also picture in picture's source when this feed has the
/// sound: the view registers the layer with the controller as it is made (and on every update, a
/// no-op when unchanged), and drops it when SwiftUI takes the view away.
private struct FeedPlayerLayer: UIViewRepresentable {
    let controller: MultiviewController
    let channelId: Int
    let player: AVPlayer?

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> FeedLayerUIView {
        let view = FeedLayerUIView()
        view.backgroundColor = .black
        // Touches go to the tile's `TileTouchSurface` above, not this view.
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        register(view, context.coordinator)
        return view
    }

    func updateUIView(_ view: FeedLayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        register(view, context.coordinator)
    }

    static func dismantleUIView(_ view: FeedLayerUIView, coordinator: Coordinator) {
        if let id = coordinator.channelId {
            coordinator.controller?.unregisterLayer(view.playerLayer, for: id)
        }
        coordinator.channelId = nil
    }

    private func register(_ view: FeedLayerUIView, _ coordinator: Coordinator) {
        if let old = coordinator.channelId, old != channelId {
            controller.unregisterLayer(view.playerLayer, for: old)
        }
        coordinator.channelId = channelId
        coordinator.controller = controller
        controller.registerLayer(view.playerLayer, for: channelId)
    }

    /// Remembers which feed the layer is registered for, for the dismantle.
    @MainActor
    final class Coordinator {
        weak var controller: MultiviewController?
        var channelId: Int?

        init(controller: MultiviewController) {
            self.controller = controller
        }
    }
}
