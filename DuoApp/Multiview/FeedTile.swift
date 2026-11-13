import AVFoundation
import F1TV
import SwiftUI
import UIKit

/// One multiview slot: the feed's picture (aspect-fit, never cropped), its name, and the red
/// SOUND badge on the main slot. An empty slot is a dark tile reading "Pick a feed".
/// The tile only shows a player; the controller owns it.
struct FeedTile: View {
    let controller: MultiviewController
    let channel: Channel?
    let slot: Int
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
        ZStack {
            Color.black
            FeedPlayerLayer(player: controller.player(for: id))
            if let problem = controller.feedProblems[id] {
                note(problem)
            } else if slot != 0 && controller.othersFrozen {
                note("Paused to keep the main feed smooth")
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Text(channel.displayTitle)
                    .rowTitle(.caption)
                    .lineLimit(1)
                if slot == 0 {
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
                let size = proxy.size
                Color.clear
                    .onChange(of: size, initial: true) { _, newSize in
                        controller.setTileSize(
                            CGSize(width: newSize.width * displayScale, height: newSize.height * displayScale),
                            for: id)
                    }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slot == 0 ? "\(channel.displayTitle), sound on" : channel.displayTitle)
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

// MARK: - Player layer

/// A view whose own layer is the `AVPlayerLayer`, so it resizes with the view.
private final class FeedLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass guarantees the type.
        layer as! AVPlayerLayer
    }
}

private struct FeedPlayerLayer: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> FeedLayerUIView {
        let view = FeedLayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: FeedLayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
