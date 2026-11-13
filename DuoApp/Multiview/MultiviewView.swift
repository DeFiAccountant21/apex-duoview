import F1TV
import SwiftUI

/// The multiview cover: the four slots in a fixed flat arrangement for now (the main feed the
/// full width, the other three in a row below it), a spinner while loading, the error with Close.
/// Tiles are keyed by their feed, so a swap moves the same tile views to new frames.
struct MultiviewView: View {
    let controller: MultiviewController

    /// A tile's identity: its feed, or the empty slot it stands in for.
    private enum TileKey: Hashable {
        case feed(Int)
        case empty(Int)
    }

    private struct TileEntry {
        let key: TileKey
        let slot: Int
        let channel: Channel?
    }

    private var entries: [TileEntry] {
        var result: [TileEntry] = []
        for (slot, channel) in controller.slots.enumerated() {
            if let channel, let id = channel.id {
                result.append(TileEntry(key: .feed(id), slot: slot, channel: channel))
            } else {
                result.append(TileEntry(key: .empty(slot), slot: slot, channel: nil))
            }
        }
        return result
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            tiles
            if controller.isLoading {
                ProgressView().controlSize(.large).tint(.white)
            }
            if let text = controller.errorText {
                Color.black.opacity(0.7).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text(text)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                    Button("Close") { controller.close() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
                .padding(24)
            }
        }
        .overlay(alignment: .topLeading) {
            if controller.errorText == nil {
                Button {
                    controller.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .padding(12)
                .accessibilityLabel("Close")
            }
        }
        .statusBarHidden(true)
    }

    private var tiles: some View {
        GeometryReader { geometry in
            let frames = Self.flatFrames(in: geometry.size)
            let shown = entries
            ForEach(shown, id: \.key) { entry in
                let frame = frames[entry.slot]
                FeedTile(
                    controller: controller,
                    channel: entry.channel,
                    slot: entry.slot,
                    showsPickPrompt: !controller.isLoading)
                    .frame(width: frame.width, height: frame.height)
                    .contentShape(Rectangle())
                    .onTapGesture { tapped(slot: entry.slot) }
                    .position(x: frame.midX, y: frame.midY)
            }
            .animation(.snappy, value: shown.map(\.key))
        }
    }

    /// Without controls yet (Task 10), a tap resumes what is paused, brings frozen feeds back,
    /// or makes the tapped feed the main one.
    private func tapped(slot: Int) {
        if controller.isPaused {
            controller.play()
        } else if controller.othersFrozen {
            controller.unfreezeOthers()
        } else if slot > 0 {
            controller.makeMain(slot: slot)
        }
    }

    /// Four 16:9 frames: the main slot the full width (less 6 pt edges), slots 1–3 side by side
    /// under it, 6 pt apart. Scaled down together and centred when the height can't hold both rows.
    static func flatFrames(in size: CGSize) -> [CGRect] {
        let gap: CGFloat = 6
        var mainWidth = max(size.width - 2 * gap, 0)
        var smallWidth = max((mainWidth - 2 * gap) / 3, 0)
        let availableHeight = max(size.height - 3 * gap, 0)
        let videoHeight = (mainWidth + smallWidth) * 9 / 16
        if videoHeight > availableHeight, videoHeight > 0 {
            let scale = availableHeight / videoHeight
            mainWidth *= scale
            smallWidth *= scale
        }
        let mainHeight = mainWidth * 9 / 16
        let smallHeight = smallWidth * 9 / 16
        let top = max((size.height - mainHeight - gap - smallHeight) / 2, 0)
        let rowWidth = smallWidth * 3 + gap * 2
        let rowX = (size.width - rowWidth) / 2
        var frames = [CGRect(x: (size.width - mainWidth) / 2, y: top, width: mainWidth, height: mainHeight)]
        for index in 0..<3 {
            frames.append(CGRect(
                x: rowX + CGFloat(index) * (smallWidth + gap),
                y: top + mainHeight + gap,
                width: smallWidth,
                height: smallHeight))
        }
        return frames
    }
}
