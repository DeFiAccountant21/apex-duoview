import CoreGraphics
import Multiview

/// What the multiview lays its tiles out by: the layout engine's posture, the fold it can use,
/// and the cover's own full-screen size (the same space as `FoldState.foldFrame`).
struct MultiviewLayoutInput: Equatable {
    var posture: Multiview.Posture
    /// Only for book and laptop: a fold on the screen, the right way round for the posture.
    var foldFrame: CGRect?
    var screen: CGSize
}

/// The pure parts of the multiview's layout: the posture mapping and the closed layout's swipe.
enum MultiviewLayout {
    /// Narrower than this (the Duo's outer screen, a phone in portrait) is the closed layout,
    /// whatever the hinge says. The same width beta.1 uses to choose the Settings panel.
    static let minimumOpenWidth: CGFloat = 600

    /// The app's posture and fold, as the layout engine takes them. Narrow or closed → closed;
    /// book or laptop with a fold the right way round on this screen → that posture and the fold;
    /// anything else (flat, unknown, or a half-open phone whose fold doesn't fit) → flat, no fold.
    /// The result is the posture the tiles really use, so a remembered layout choice is stored
    /// under it.
    static func input(posture: Posture, foldFrame: CGRect?, screen: CGSize) -> MultiviewLayoutInput {
        if screen.width < minimumOpenWidth || posture == .closed {
            return MultiviewLayoutInput(posture: .closed, foldFrame: nil, screen: screen)
        }
        switch posture {
        case .book:
            if let fold = usableFold(foldFrame, screen: screen, tall: true) {
                return MultiviewLayoutInput(posture: .book, foldFrame: fold, screen: screen)
            }
        case .laptop:
            if let fold = usableFold(foldFrame, screen: screen, tall: false) {
                return MultiviewLayoutInput(posture: .laptop, foldFrame: fold, screen: screen)
            }
        case .closed, .flat, .unknown:
            break
        }
        return MultiviewLayoutInput(posture: .flat, foldFrame: nil, screen: screen)
    }

    /// The fold clipped to the screen; nil when it misses it or lies the wrong way (book needs it
    /// taller than wide, laptop wider than tall). A fold reported as a line with no thickness
    /// (Settings › Debug's simulated fold) is widened to 1 pt first: the layout engine only takes
    /// a fold with an area.
    static func usableFold(_ frame: CGRect?, screen: CGSize, tall: Bool) -> CGRect? {
        guard var fold = frame, screen.width > 0, screen.height > 0 else { return nil }
        if fold.width <= 0, fold.height > 0 {
            fold = CGRect(x: fold.minX - 0.5, y: fold.minY, width: 1, height: fold.height)
        } else if fold.height <= 0, fold.width > 0 {
            fold = CGRect(x: fold.minX, y: fold.minY - 0.5, width: fold.width, height: 1)
        }
        let clipped = fold.intersection(CGRect(origin: .zero, size: screen))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        if tall { return clipped.height > clipped.width ? clipped : nil }
        return clipped.width > clipped.height ? clipped : nil
    }

    /// The slot whose feed a swipe on the closed layout makes the main one, or nil.
    ///
    /// Taking the main spot trades places with slot 0, so "the next slot" would only ever trade
    /// the same two feeds back and forth. Instead the swipe steps through the filled feeds in a
    /// fixed order, the session's feed list (`order`), wrapping, and skips feeds that can't take
    /// the main spot (`playable` lacks them). Forward is a swipe to the left.
    static func swipeSlot(slots: [Int?], order: [Int], forward: Bool, playable: Set<Int>) -> Int? {
        guard let main = slots.first ?? nil else { return nil }
        let filled = slots.compactMap { $0 }
        guard filled.count > 1 else { return nil }
        // Feeds missing from `order` go last, by id: never by slot, which the swipe itself changes.
        func rank(_ id: Int) -> (Int, Int) {
            (order.firstIndex(of: id) ?? order.count, id)
        }
        let cycle = filled.sorted { rank($0) < rank($1) }
        guard let start = cycle.firstIndex(of: main) else { return nil }
        let step = forward ? 1 : cycle.count - 1
        var index = start
        for _ in 1..<cycle.count {
            index = (index + step) % cycle.count
            let id = cycle[index]
            if playable.contains(id) { return slots.firstIndex(of: id) }
        }
        return nil
    }
}
