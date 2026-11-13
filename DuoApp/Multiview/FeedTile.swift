import AVFoundation
import F1TV
import SwiftUI
import UIKit

/// One multiview slot: the feed's picture (aspect-fit, never cropped), its name, the red SOUND
/// badge on the feed with the sound, and a speaker button (top right) that moves the sound to
/// this feed. An empty slot is a dark tile reading "Pick a feed".
/// The tile only shows a player; the controller owns it.
struct FeedTile: View {
    let controller: MultiviewController
    let channel: Channel?
    let slot: Int
    /// False while the layout hides this feed (it plays on, out of sight): it then asks for the
    /// lowest quality instead of its tile's size.
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
            FeedPlayerLayer(player: controller.player(for: id))
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
                // A hidden feed needs no picture: the smallest size asks for the lowest quality.
                let size = isVisible ? proxy.size : CGSize(width: 1, height: 1)
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
        .accessibilityLabel(hasSound ? "\(channel.displayTitle), sound on" : channel.displayTitle)
        .accessibilityAddTraits(slot == 0 ? AccessibilityTraits() : .isButton)
        // After the tile's own accessibility element, so the button stays its own element; its
        // own Button, so a tap on it never reaches the tile's tap or drag.
        .overlay(alignment: .topTrailing) {
            if problem == nil {
                speakerButton(id: id, title: channel.displayTitle, hasSound: hasSound)
            }
        }
    }

    /// The speaker: on the feed with the sound a speaker with waves, on the others a crossed-out
    /// one; tapping it moves the sound here. A 44 pt hit area around a smaller disc.
    private func speakerButton(id: Int, title: String, hasSound: Bool) -> some View {
        Button {
            controller.setAudio(channelId: id)
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
        // Taps go to the SwiftUI tile, not this view.
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: FeedLayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
