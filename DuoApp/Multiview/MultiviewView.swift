import F1TV
import Multiview
import SwiftUI

/// The multiview cover: the tiles laid out by the fold (flat, book, laptop, closed) with
/// `LayoutEngine`, a spinner while loading, the error with Close.
///
/// One view per feed, keyed by the feed, inside one `ForEach`, each placed with `.frame` and
/// `.position` from its `TileFrame`; a posture, layout or swap change moves the same views to new
/// frames with a glide (the beta.1 `SettingsPanel` technique), so a video layer is never rebuilt.
/// Hidden feeds keep playing, out of sight, under the main one.
///
/// Touch: a tap swaps a feed with the main one; press and hold, then drag a feed onto another to
/// trade places; on the closed layout a horizontal swipe changes the main feed; each tile's
/// speaker button moves the sound.
///
/// Coordinates: the inner reader ignores the safe area, so its space is the full screen, the same
/// space as `FoldState.foldFrame` and as the drag's global locations. The outer reader keeps the
/// safe area only to read its insets, for the top bar.
struct MultiviewView: View {
    let controller: MultiviewController
    let fold: FoldState

    /// The tile being dragged and how far it has moved. Back to nil when the finger lifts, which
    /// glides the tile home (or, after a trade, into its new place).
    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var drag: TileDrag? = nil
    /// The tile dragged last stays above the others while it glides into place.
    @State private var raised: TileKey?

    /// How long a press is held before the tile lifts and follows the finger.
    static let holdBeforeDrag: Double = 0.35
    /// How far a horizontal swipe on the closed layout goes before it changes the main feed.
    static let swipeDistance: CGFloat = 60

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

    private struct PlacedTile: Identifiable {
        let entry: TileEntry
        let frame: TileFrame
        var id: TileKey { entry.key }
    }

    private struct TileDrag: Equatable {
        var key: TileKey
        var translation: CGSize
    }

    /// What the glide animates on: every tile's frame and the reserved area.
    private struct Placement: Equatable {
        var frames: [TileKey: TileFrame]
        var reserved: CGRect?
    }

    private struct Arrangement {
        var input: MultiviewLayoutInput
        var feedCount: Int
        /// The layouts ⟳ cycles through: those that fit this screen.
        var usableOptions: [String]
        var tiles: [PlacedTile]
        var reserved: CGRect?

        var visibleCount: Int { tiles.filter(\.frame.visible).count }

        var placement: Placement {
            var frames: [TileKey: TileFrame] = [:]
            for tile in tiles { frames[tile.id] = tile.frame }
            return Placement(frames: frames, reserved: reserved)
        }
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
        GeometryReader { safe in
            let insets = safe.safeAreaInsets
            GeometryReader { proxy in
                let layout = arrangement(screen: proxy.size)
                ZStack(alignment: .topLeading) {
                    Color.black
                    if let rect = layout.reserved {
                        ReservedArea()
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .transition(.opacity)
                    }
                    ForEach(layout.tiles) { placed in
                        tile(placed, in: layout)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                // Frames glide; the drag itself isn't part of this value, so it tracks the finger.
                .animation(.snappy, value: layout.placement)
                .simultaneousGesture(swipe, including: layout.input.posture == .closed ? .all : .subviews)
                .overlay(alignment: .topLeading) {
                    topBar(layout)
                        .padding(.top, insets.top)
                        .padding(.leading, insets.leading)
                }
            }
            .ignoresSafeArea()
        }
        .overlay { status }
        .statusBarHidden(true)
        // The cover reads the fold too: the root's reader sits under the cover, and may not see
        // a change while the cover is up. Both write the same full-screen values; `FoldState`
        // only publishes real changes.
        .foldTracking(fold)
    }

    // MARK: Layout

    /// The tiles' frames for this screen. Until the "fewer feeds" choice (Task 9), the layout fits
    /// the filled slots; empty slots are only laid out ("Pick a feed") when all four are empty.
    private func arrangement(screen: CGSize) -> Arrangement {
        let input = MultiviewLayout.input(posture: fold.posture, foldFrame: fold.foldFrame, screen: screen)
        let all = entries
        let filled = all.filter { $0.channel != nil }
        let shown = filled.isEmpty ? all : filled
        let count = shown.count
        let option = controller.layoutOption(for: input.posture, feedCount: count)
        let frames = LayoutEngine.frames(
            screen: screen, foldFrame: input.foldFrame, posture: input.posture,
            feedCount: count, optionID: option)
        return Arrangement(
            input: input,
            feedCount: count,
            usableOptions: LayoutEngine.usableOptionIDs(
                screen: screen, foldFrame: input.foldFrame, posture: input.posture, feedCount: count),
            tiles: zip(shown, frames).map { PlacedTile(entry: $0.0, frame: $0.1) },
            reserved: LayoutEngine.reservedArea(
                screen: screen, foldFrame: input.foldFrame, posture: input.posture, feedCount: count))
    }

    private func tile(_ placed: PlacedTile, in layout: Arrangement) -> some View {
        let entry = placed.entry
        let rect = placed.frame.rect
        let visible = placed.frame.visible
        let dragging = drag?.key == entry.key
        // Nothing to drop on when only one tile shows (the closed layout, one feed, across the fold).
        let canDrag = entry.channel != nil && visible && layout.visibleCount > 1
        return FeedTile(
            controller: controller,
            channel: entry.channel,
            slot: entry.slot,
            showsPickPrompt: !controller.isLoading)
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            // The hold-and-drag is attached inside the tap, so it takes precedence: a press that
            // was held never ends as a tap. The speaker button is a Button inside the tile, which
            // takes precedence over both.
            .gesture(moveGesture(entry, in: layout), including: canDrag ? .all : .subviews)
            .onTapGesture { tapped(slot: entry.slot) }
            .scaleEffect(dragging ? 1.03 : 1)
            .offset(dragging ? (drag?.translation ?? .zero) : .zero)
            .position(x: rect.midX, y: rect.midY)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .zIndex(dragging ? 2 : (raised == entry.key ? 1 : 0))
    }

    // MARK: Gestures

    /// Press and hold, then drag: the tile lifts and follows the finger; let go over another tile
    /// and the two trade places, anywhere else and it glides back.
    private func moveGesture(_ entry: TileEntry, in layout: Arrangement) -> some Gesture {
        let key = entry.key
        let slot = entry.slot
        // Hidden tiles share the main tile's frame: only the visible ones are drop targets.
        let targets = layout.tiles.filter { $0.frame.visible && $0.id != key }
        return LongPressGesture(minimumDuration: Self.holdBeforeDrag)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($drag) { value, state, _ in
                if case .second(true, let change) = value {
                    state = TileDrag(key: key, translation: change?.translation ?? .zero)
                }
            }
            .onEnded { value in
                guard case .second(true, let change?) = value else { return }
                raised = key
                if let target = targets.first(where: { $0.frame.rect.contains(change.location) }) {
                    controller.moveFeed(from: slot, to: target.entry.slot)
                }
            }
    }

    /// The closed layout: a horizontal swipe makes the next (left) or previous (right) feed the
    /// main one, wrapping. Only enabled on the closed layout.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > Self.swipeDistance, abs(dx) > abs(dy) else { return }
                swipeMain(forward: dx < 0)
            }
    }

    private func swipeMain(forward: Bool) {
        let ids = controller.slots.map { $0?.id }
        let playable = Set(ids.compactMap { $0 }.filter { controller.canBeMain(channelId: $0) })
        guard let slot = MultiviewLayout.swipeSlot(
            slots: ids, order: controller.channels.compactMap(\.id), forward: forward, playable: playable)
        else { return }
        controller.makeMain(slot: slot)
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

    // MARK: Chrome

    /// Close, and "Switch layout" when this screen has more than one layout for these feeds.
    /// (Task 10 moves ⟳ into the full controls.)
    private func topBar(_ layout: Arrangement) -> some View {
        HStack(spacing: 8) {
            if controller.errorText == nil {
                Button {
                    controller.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .accessibilityLabel("Close")
                if layout.usableOptions.count > 1 {
                    Button {
                        controller.cycleLayout(
                            posture: layout.input.posture, feedCount: layout.feedCount,
                            usable: layout.usableOptions)
                    } label: {
                        Label("Switch layout", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote.bold())
                            .fontWidth(.condensed)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(Color.black.opacity(0.5), in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var status: some View {
        if controller.isLoading {
            ProgressView().controlSize(.large).tint(.white)
        }
        if let text = controller.errorText {
            ZStack {
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
    }
}
