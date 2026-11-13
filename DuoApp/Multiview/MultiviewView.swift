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
/// speaker button moves the sound; a "Pick a feed" tile opens the feeds editor on its slot.
///
/// Feeds: the top bar's "Feeds" opens the feeds editor (a sheet). With fewer than four feeds the
/// once-only "fewer feeds" question shows, never over the editor.
///
/// Touches on a tile are UIKit gesture recognizers (`TileTouchSurface`); SwiftUI's tap and
/// long-press-then-drag on the same tile stopped both from firing.
///
/// Coordinates: the inner reader ignores the safe area, so its space is the full screen, the same
/// space as `FoldState.foldFrame` and, on this full-screen cover, as the window coordinates the
/// drag reports. The outer reader keeps the safe area only to read its insets.
struct MultiviewView: View {
    let controller: MultiviewController
    let fold: FoldState

    /// The tile being dragged and how far it has moved. Back to nil (with `.snappy`) when the
    /// finger lifts, which glides the tile home or, after a trade, into its new place.
    @State private var drag: TileDrag?
    /// The tile dragged last stays above the others while it glides into place.
    @State private var raised: TileKey?
    /// The feeds editor, while it is asked for.
    @State private var editor: EditorRequest?
    /// True from opening the editor until its sheet has finished closing: the "fewer feeds"
    /// question waits for that, so it is never presented over the editor or during its dismissal.
    @State private var editorShowing = false

    /// How long a press is held before the tile lifts and follows the finger.
    static let holdBeforeDrag: Double = 0.35
    /// How far a horizontal swipe on the closed layout goes before it changes the main feed.
    static let swipeDistance: CGFloat = 60

    private struct EditorRequest: Identifiable {
        let id = UUID()
        /// Opens straight on this slot's feed list.
        let slot: Int?
    }

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
                let layout = arrangement(screen: proxy.size, insets: insets)
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
                .overlay(alignment: .topLeading) {
                    topBar(layout)
                        .padding(.top, insets.top)
                        .padding(.leading, insets.leading)
                }
            }
            .ignoresSafeArea()
        }
        .overlay { status }
        // An editor reopened while the last one was still closing keeps the question waiting.
        .sheet(item: $editor, onDismiss: { editorShowing = editor != nil }) { request in
            FeedsEditor(controller: controller, startSlot: request.slot)
        }
        .fewerFeedsPrompt(controller, enabled: !editorShowing)
        .statusBarHidden(true)
        // The cover reads the fold too: the root's reader sits under the cover, and may not see
        // a change while the cover is up. Both write the same full-screen values; `FoldState`
        // only publishes real changes.
        .foldTracking(fold)
    }

    // MARK: Layout

    /// The tiles' frames for this screen, in full-screen coordinates. The tiles are laid out inside
    /// the safe area (spec: tiles stay out of cutouts; the optional edge-to-edge main feed is left
    /// out), and the closed check still uses the whole screen's width. With "keep four spots" (or
    /// no feed at all) the layout has four tiles and every empty slot shows "Pick a feed" in its
    /// slot's frame (slot index = frame index; slot 0 always has a feed when any slot does);
    /// otherwise it fits the filled slots.
    private func arrangement(screen full: CGSize, insets: EdgeInsets) -> Arrangement {
        let safeRect = CGRect(
            x: insets.leading,
            y: insets.top,
            width: full.width - insets.leading - insets.trailing,
            height: full.height - insets.top - insets.bottom)
        let input = MultiviewLayout.input(
            posture: fold.posture, foldFrame: fold.foldFrame, screen: full, safeRect: safeRect)
        // The engine works in the safe area's own space; its rects are shifted back to be drawn.
        let screen = input.screen
        let all = entries
        let filled = all.filter { $0.channel != nil }
        let shown = controller.effectiveFeedCount == all.count ? all : filled
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
            tiles: zip(shown, frames).map {
                PlacedTile(entry: $0.0, frame: TileFrame(rect: input.onScreen($0.1.rect), visible: $0.1.visible))
            },
            reserved: LayoutEngine.reservedArea(
                screen: screen, foldFrame: input.foldFrame, posture: input.posture, feedCount: count)
                .map { input.onScreen($0) })
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
            isVisible: visible,
            showsPickPrompt: !controller.isLoading)
            .frame(width: rect.width, height: rect.height)
            .overlay {
                TileTouchSurface(
                    isActive: visible,
                    canDrag: canDrag,
                    canSwipe: visible && layout.input.posture == .closed,
                    holdDuration: Self.holdBeforeDrag,
                    onTap: { tapped(slot: entry.slot) },
                    onDrag: { event in dragged(entry, event, in: layout) },
                    onSwipe: { translation in swiped(translation) })
            }
            // The speaker sits above the touch surface, so it answers its own taps. It moves
            // with the tile.
            .overlay(alignment: .topTrailing) {
                if let channel = entry.channel, let id = channel.id, controller.feedProblems[id] == nil {
                    FeedSpeakerButton(controller: controller, channelId: id, title: channel.displayTitle)
                }
            }
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
    /// and the two trade places, anywhere else (or if the system takes the touch) it glides back.
    /// The finger's window point is used as a full-screen point: on this full-screen cover, whose
    /// inner reader ignores the safe area, the two spaces are the same.
    private func dragged(_ entry: TileEntry, _ event: TileDragEvent, in layout: Arrangement) {
        let key = entry.key
        switch event {
        case .began:
            raised = key
            drag = TileDrag(key: key, translation: .zero)
        case .moved(let translation):
            // Not animated: the tile tracks the finger.
            drag = TileDrag(key: key, translation: translation)
        case .ended(let point):
            // Hidden tiles share the main tile's frame: only the visible ones are drop targets.
            let target = layout.tiles.first { $0.frame.visible && $0.id != key && $0.frame.rect.contains(point) }
            withAnimation(.snappy) {
                drag = nil
                if let target { controller.moveFeed(from: entry.slot, to: target.entry.slot) }
            }
        case .cancelled:
            withAnimation(.snappy) { drag = nil }
        }
    }

    /// The closed layout: a horizontal swipe makes the next (left) or previous (right) feed the
    /// main one, wrapping. The pan is only enabled on the closed layout.
    private func swiped(_ translation: CGSize) {
        let dx = translation.width
        let dy = translation.height
        guard abs(dx) > Self.swipeDistance, abs(dx) > abs(dy) else { return }
        swipeMain(forward: dx < 0)
    }

    private func swipeMain(forward: Bool) {
        let ids = controller.slots.map { $0?.id }
        let playable = Set(ids.compactMap { $0 }.filter { controller.canBeMain(channelId: $0) })
        guard let slot = MultiviewLayout.swipeSlot(
            slots: ids, order: controller.channels.compactMap(\.id), forward: forward, playable: playable)
        else { return }
        controller.makeMain(slot: slot)
    }

    /// Without controls yet (Task 10), a tap on a "Pick a feed" tile opens the feeds editor on
    /// that slot; any other tap resumes what is paused, brings frozen feeds back, or makes the
    /// tapped feed the main one.
    private func tapped(slot: Int) {
        if controller.slots.indices.contains(slot), controller.slots[slot] == nil {
            openEditor(slot: slot)
        } else if controller.isPaused {
            controller.play()
        } else if controller.othersFrozen {
            controller.unfreezeOthers()
        } else if slot > 0 {
            controller.makeMain(slot: slot)
        }
    }

    private func openEditor(slot: Int?) {
        // Not before the session's feeds are known, and not over an error.
        guard controller.errorText == nil, !controller.channels.isEmpty, editor == nil else { return }
        editorShowing = true
        editor = EditorRequest(slot: slot)
    }

    // MARK: Chrome

    /// Close, "Switch layout" when this screen has more than one layout for these feeds, and
    /// "Feeds" (the feeds editor). (Task 10 moves them into the full controls.)
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
                if !controller.channels.isEmpty {
                    Button {
                        openEditor(slot: nil)
                    } label: {
                        chromeLabel("Feeds", systemImage: "rectangle.grid.2x2")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
    }

    /// A top-bar button's look: white condensed text on a dark capsule, in a 44 pt high hit area.
    private func chromeLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.bold())
            .fontWidth(.condensed)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Color.black.opacity(0.5), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
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
