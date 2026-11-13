import CoreGraphics
import Multiview

/// What the multiview lays its tiles out by: the layout engine's posture, the fold it can use,
/// and the area the tiles go in. `screen` and `foldFrame` are in the layout area's own space
/// (origin at its top-left corner); `origin` is where that area sits in the full screen (the space
/// of `FoldState.foldFrame`), so the engine's frames are shifted by it to be drawn.
struct MultiviewLayoutInput: Equatable {
    var posture: Multiview.Posture
    /// Only for book and laptop: a fold in the layout area, the right way round for the posture.
    var foldFrame: CGRect?
    var screen: CGSize
    var origin: CGPoint = .zero

    /// A rect from the layout engine, in full-screen coordinates.
    func onScreen(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: origin.x, dy: origin.y)
    }
}

/// The pure parts of the multiview's layout: the posture mapping and the closed layout's swipe.
enum MultiviewLayout {
    /// Narrower than this (the Duo's outer screen, a phone in portrait) is the closed layout,
    /// whatever the hinge says. The same width beta.1 uses to choose the Settings panel.
    static let minimumOpenWidth: CGFloat = 600

    /// The app's posture and fold, as the layout engine takes them, with the whole screen as the
    /// layout area.
    static func input(posture: Posture, foldFrame: CGRect?, screen: CGSize) -> MultiviewLayoutInput {
        input(posture: posture, foldFrame: foldFrame, screen: screen,
              safeRect: CGRect(origin: .zero, size: screen))
    }

    /// The app's posture and fold, as the layout engine takes them, laid out inside `safeRect`
    /// (the safe area, in full-screen coordinates; the spec keeps tiles out of cutouts). Closed
    /// when the whole screen is narrower than 600 pt or the posture is closed; book or laptop with
    /// a fold the right way round in the safe area → that posture and the fold (in the safe
    /// area's space); anything else (flat, unknown, or a half-open phone whose fold doesn't fit)
    /// → flat, no fold. The result is the posture the tiles really use, so a remembered layout
    /// choice is stored under it. An empty safe rect falls back to the whole screen.
    static func input(posture: Posture, foldFrame: CGRect?, screen: CGSize, safeRect: CGRect) -> MultiviewLayoutInput {
        let area = safeRect.width > 0 && safeRect.height > 0 ? safeRect : CGRect(origin: .zero, size: screen)
        func result(_ posture: Multiview.Posture, _ fold: CGRect?) -> MultiviewLayoutInput {
            MultiviewLayoutInput(posture: posture, foldFrame: fold, screen: area.size, origin: area.origin)
        }
        if screen.width < minimumOpenWidth || posture == .closed { return result(.closed, nil) }
        let shifted = foldFrame?.offsetBy(dx: -area.minX, dy: -area.minY)
        switch posture {
        case .book:
            if let fold = usableFold(shifted, screen: area.size, tall: true) { return result(.book, fold) }
        case .laptop:
            if let fold = usableFold(shifted, screen: area.size, tall: false) { return result(.laptop, fold) }
        case .closed, .flat, .unknown:
            break
        }
        return result(.flat, nil)
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
