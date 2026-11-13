import Testing
import Foundation
@testable import Multiview

@Suite struct LayoutEngineTests {
    struct Reference: Decodable {
        struct Entry: Decodable {
            let posture: String
            let feeds: Int
            let id: String
            let visible: Int
            let frames: [[Double]]
        }
        let layouts: [Entry]
    }

    static func loadReference() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/layouts-reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    /// Screen and fold used by the reference JSON.
    static func referenceGeometry(_ posture: Posture) -> (CGSize, CGRect) {
        posture == .laptop
            ? (CGSize(width: 669, height: 951), CGRect(x: 0, y: 456, width: 669, height: 40))
            : (CGSize(width: 951, height: 669), CGRect(x: 456, y: 0, width: 40, height: 669))
    }

    /// A 40 pt fold centred on `screen`; horizontal for laptop, vertical otherwise. The reference
    /// folds are used where the screen matches the reference screen for that posture.
    static func fold(for posture: Posture, screen: CGSize) -> CGRect {
        let ref = referenceGeometry(posture)
        if ref.0 == screen { return ref.1 }
        return posture == .laptop
            ? CGRect(x: 0, y: (screen.height - 40) / 2, width: screen.width, height: 40)
            : CGRect(x: (screen.width - 40) / 2, y: 0, width: 40, height: screen.height)
    }

    @Test func matchesReferenceFrames() throws {
        let ref = try Self.loadReference()
        #expect(!ref.layouts.isEmpty)
        for e in ref.layouts {
            let posture = try #require(Posture(rawValue: e.posture))
            let (screen, fold) = Self.referenceGeometry(posture)
            let frames = LayoutEngine.frames(screen: screen, foldFrame: fold, posture: posture,
                                             feedCount: e.feeds, optionID: e.id)
            #expect(frames.count == e.feeds, "\(e.id)/\(e.feeds)")
            let visible = frames.filter(\.visible)
            #expect(visible.count == e.visible, "\(e.id)/\(e.feeds)")
            for (f, r) in zip(visible, e.frames) {
                #expect(abs(f.rect.minX - r[0]) < 0.5, "\(e.id)/\(e.feeds) x")
                #expect(abs(f.rect.minY - r[1]) < 0.5, "\(e.id)/\(e.feeds) y")
                #expect(abs(f.rect.width - r[2]) < 0.5, "\(e.id)/\(e.feeds) w")
                #expect(abs(f.rect.height - r[3]) < 0.5, "\(e.id)/\(e.feeds) h")
            }
        }
    }

    @Test func defaultsAreFirstOption() {
        #expect(LayoutEngine.optionIDs(posture: .book, feedCount: 1).first == "book.across")
        #expect(LayoutEngine.optionIDs(posture: .flat, feedCount: 4).first == "flat.mainBelow")
        #expect(LayoutEngine.optionIDs(posture: .laptop, feedCount: 4) == ["laptop.pyramid"])
        #expect(LayoutEngine.optionIDs(posture: .closed, feedCount: 3) == ["closed.main"])
        #expect(LayoutEngine.optionIDs(posture: .unknown, feedCount: 2) == LayoutEngine.optionIDs(posture: .flat, feedCount: 2))
    }

    @Test func screenUseFloors() {
        // Floors are the spec table's percentages rounded to 0.1%, so compare after rounding to 0.1% (true values are up to 0.04% below).
        for (posture, floor) in [(Posture.flat, 0.906), (.book, 0.696), (.laptop, 0.663)] {
            let (screen, fold) = Self.referenceGeometry(posture)
            let frames = LayoutEngine.frames(screen: screen, foldFrame: fold, posture: posture,
                                             feedCount: 4, optionID: nil)
            let use = LayoutEngine.screenUse(frames, screen: screen)
            #expect((use * 1000).rounded() / 1000 >= floor - 1e-9, "\(posture) \(use)")
        }
    }

    static let screens = [CGSize(width: 951, height: 669), CGSize(width: 669, height: 951),
                          CGSize(width: 1020, height: 700)]

    @Test func everyTileIs16x9OnScreenAndWideEnough() {
        for screen in Self.screens {
            let bounds = CGRect(origin: .zero, size: screen)
            for posture in Posture.allCases {
                for n in 1...4 {
                    for id in LayoutEngine.optionIDs(posture: posture, feedCount: n) {
                        let frames = LayoutEngine.frames(screen: screen,
                                                         foldFrame: Self.fold(for: posture, screen: screen),
                                                         posture: posture, feedCount: n, optionID: id)
                        #expect(frames.count == n)
                        #expect(frames.first?.visible == true)
                        for f in frames where f.visible {
                            let tag = "\(posture) \(id) n=\(n) \(screen) \(f.rect)"
                            #expect(bounds.contains(f.rect), "\(tag)")
                            if posture != .closed { #expect(f.rect.width >= 200 - 0.01, "\(tag)") }
                            #expect(abs(f.rect.width * 9 / 16 - f.rect.height) < 0.5, "\(tag)")
                        }
                    }
                }
            }
        }
    }

    @Test func nothingCrossesTheFoldUnlessAcross() {
        for screen in Self.screens {
            for posture in [Posture.book, .laptop] {
                let fold = Self.fold(for: posture, screen: screen)
                for n in 1...4 {
                    for id in LayoutEngine.optionIDs(posture: posture, feedCount: n) where id != "book.across" {
                        let frames = LayoutEngine.frames(screen: screen, foldFrame: fold, posture: posture,
                                                         feedCount: n, optionID: id)
                        for f in frames where f.visible {
                            #expect(!f.rect.intersects(fold), "\(id) n=\(n) \(screen) \(f.rect)")
                        }
                    }
                }
            }
        }
    }

    @Test func bookWithoutFoldFallsBackToFlat() {
        let screen = CGSize(width: 951, height: 669)
        for posture in [Posture.book, .laptop] {
            for n in 1...4 {
                let a = LayoutEngine.frames(screen: screen, foldFrame: nil, posture: posture, feedCount: n, optionID: nil)
                let b = LayoutEngine.frames(screen: screen, foldFrame: nil, posture: .flat, feedCount: n, optionID: nil)
                #expect(a == b)
            }
        }
    }

    @Test func unknownOrNilOptionMeansDefault() {
        let (screen, fold) = Self.referenceGeometry(.flat)
        let d = LayoutEngine.frames(screen: screen, foldFrame: fold, posture: .flat, feedCount: 3, optionID: nil)
        let u = LayoutEngine.frames(screen: screen, foldFrame: fold, posture: .flat, feedCount: 3, optionID: "nope")
        let first = LayoutEngine.frames(screen: screen, foldFrame: fold, posture: .flat, feedCount: 3, optionID: "flat.mainBelow")
        #expect(d == first)
        #expect(u == first)
    }

    @Test func closedFillsScreen() {
        let screen = CGSize(width: 844, height: 390)
        let frames = LayoutEngine.frames(screen: screen, foldFrame: nil, posture: .closed, feedCount: 3, optionID: nil)
        #expect(frames.count == 3)
        #expect(frames[0].visible)
        #expect(abs(frames[0].rect.width - 693.3) < 0.1)
        #expect(abs(frames[0].rect.height - 390) < 0.01)
        #expect(abs(frames[0].rect.midX - 422) < 0.01)
        #expect(frames.dropFirst().allSatisfy { !$0.visible && $0.rect == frames[0].rect })
    }

    @Test func reservedAreaOnlyForLaptopOneFeed() {
        let (screen, fold) = Self.referenceGeometry(.laptop)
        let r = LayoutEngine.reservedArea(screen: screen, foldFrame: fold, posture: .laptop, feedCount: 1)
        #expect(r == CGRect(x: 6, y: 502, width: 657, height: 443))
        #expect(LayoutEngine.reservedArea(screen: screen, foldFrame: fold, posture: .laptop, feedCount: 2) == nil)
        #expect(LayoutEngine.reservedArea(screen: screen, foldFrame: fold, posture: .flat, feedCount: 1) == nil)
        #expect(LayoutEngine.reservedArea(screen: screen, foldFrame: fold, posture: .book, feedCount: 1) == nil)
    }

    // MARK: Degenerate inputs and fallbacks

    static let oddScreens = [CGSize(width: 400, height: 700), CGSize(width: 700, height: 400),
                             CGSize(width: 320, height: 480), CGSize(width: 951, height: 669),
                             CGSize(width: 100, height: 100), CGSize(width: 10, height: 10)]
    static let oddFolds: [CGRect?] = [
        nil,
        CGRect(x: 180, y: 0, width: 40, height: 700),        // vertical, centred on 400 wide
        CGRect(x: 0, y: 330, width: 700, height: 40),        // horizontal
        CGRect(x: 5000, y: 5000, width: 40, height: 700),    // outside every screen
        CGRect(x: -100, y: -100, width: 300, height: 5000),  // overhangs, vertical
        CGRect(x: 300, y: 0, width: 40, height: 5000),       // overhangs bottom
        CGRect(x: 0, y: 0, width: 0, height: 0),
    ]

    @Test func degenerateInputsAlwaysYieldValidFrames() {
        for screen in Self.oddScreens {
            let bounds = CGRect(origin: .zero, size: screen).insetBy(dx: -0.01, dy: -0.01)
            for fold in Self.oddFolds {
                for posture in Posture.allCases {
                    for n in 1...6 {
                        let ids = (LayoutEngine.optionIDs(posture: posture, feedCount: n).map { Optional($0) }) + [nil, "bogus"]
                        for id in ids {
                            let frames = LayoutEngine.frames(screen: screen, foldFrame: fold, posture: posture,
                                                             feedCount: n, optionID: id)
                            let tag = "\(posture) \(String(describing: id)) n=\(n) \(screen) \(String(describing: fold))"
                            #expect(frames.count == n, "\(tag)")
                            #expect(frames.first?.visible == true, "\(tag)")
                            for f in frames {
                                #expect(f.rect.width >= 0 && f.rect.height >= 0, "\(tag)")
                                #expect(bounds.contains(f.rect), "\(tag) \(f.rect)")
                                if !f.visible { #expect(f.rect == frames[0].rect, "\(tag)") }
                            }
                            // Multi-tile layouts never enter a usable fold, after any fallback.
                            if let fold, posture == .book || posture == .laptop, frames.filter(\.visible).count > 1 {
                                let clipped = fold.intersection(CGRect(origin: .zero, size: screen))
                                let usable = !clipped.isNull && clipped.width > 0 && clipped.height > 0
                                    && (posture == .book ? clipped.height > clipped.width : clipped.width > clipped.height)
                                if usable {
                                    for f in frames where f.visible { #expect(!f.rect.intersects(clipped), "\(tag)") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func feedCountEdges() {
        let screen = CGSize(width: 951, height: 669)
        #expect(LayoutEngine.frames(screen: screen, foldFrame: nil, posture: .flat, feedCount: 0, optionID: nil).isEmpty)
        #expect(LayoutEngine.frames(screen: screen, foldFrame: nil, posture: .flat, feedCount: -1, optionID: nil).isEmpty)
        let five = LayoutEngine.frames(screen: screen, foldFrame: nil, posture: .flat, feedCount: 5, optionID: nil)
        #expect(five.count == 5)
        #expect(five[4].visible == false && five[4].rect == five[0].rect)
        let zero = LayoutEngine.frames(screen: .zero, foldFrame: nil, posture: .flat, feedCount: 3, optionID: nil)
        #expect(zero.count == 3)
        #expect(zero.allSatisfy { !$0.visible && $0.rect == .zero })
    }

    @Test func nothingCrossesTheFoldOnNarrowScreens() {
        // Includes fallbacks: multi-tile layouts stay out of the fold; a lone fallback tile may not.
        for screen in [CGSize(width: 400, height: 700), CGSize(width: 700, height: 400), CGSize(width: 520, height: 900)] {
            for posture in [Posture.book, .laptop] {
                let fold = posture == .laptop
                    ? CGRect(x: 0, y: screen.height / 2 - 20, width: screen.width, height: 40)
                    : CGRect(x: screen.width / 2 - 20, y: 0, width: 40, height: screen.height)
                for n in 1...4 {
                    for id in LayoutEngine.optionIDs(posture: posture, feedCount: n) + [""] where id != "book.across" {
                        let frames = LayoutEngine.frames(screen: screen, foldFrame: fold, posture: posture,
                                                         feedCount: n, optionID: id)
                        #expect(frames.count == n)
                        let visible = frames.filter(\.visible)
                        if visible.count > 1 {
                            for f in visible { #expect(!f.rect.intersects(fold), "\(posture) \(id) n=\(n) \(screen) \(f.rect)") }
                        }
                    }
                }
            }
        }
    }

    @Test func usableOptionIDsSkipsUnfittingOptions() {
        let screen = CGSize(width: 400, height: 700)
        let fold = CGRect(x: 180, y: 0, width: 40, height: 700)
        // Halves are 174 wide: no per-side option fits, only across does.
        #expect(LayoutEngine.usableOptionIDs(screen: screen, foldFrame: fold, posture: .book, feedCount: 4) == ["book.across"])
        #expect(LayoutEngine.usableOptionIDs(screen: screen, foldFrame: fold, posture: .book, feedCount: 1) == ["book.across"])
        // A roomy screen keeps everything.
        let (s, f) = Self.referenceGeometry(.book)
        #expect(LayoutEngine.usableOptionIDs(screen: s, foldFrame: f, posture: .book, feedCount: 2) == ["book.perScreen", "book.across"])
        // Never empty, even on a tiny screen.
        #expect(LayoutEngine.usableOptionIDs(screen: CGSize(width: 50, height: 50), foldFrame: nil, posture: .flat, feedCount: 4) == ["flat.mainBelow"])
        // Every usable option really lays out as itself with tiles of 200 pt or more.
        for id in LayoutEngine.usableOptionIDs(screen: s, foldFrame: f, posture: .book, feedCount: 4) {
            let fr = LayoutEngine.frames(screen: s, foldFrame: f, posture: .book, feedCount: 4, optionID: id)
            #expect(fr.filter(\.visible).allSatisfy { $0.rect.width >= 200 })
        }
    }

    @Test func bookOnePerScreenWithFourFeeds() {
        let (s, f) = Self.referenceGeometry(.book)
        let two = LayoutEngine.frames(screen: s, foldFrame: f, posture: .book, feedCount: 2, optionID: "book.perScreen")
        for n in [3, 4] {
            let frames = LayoutEngine.frames(screen: s, foldFrame: f, posture: .book, feedCount: n, optionID: "book.perScreen")
            #expect(frames.count == n)
            #expect(Array(frames.prefix(2)) == two, "n=\(n)")
            for hidden in frames.dropFirst(2) {
                #expect(hidden.visible == false && hidden.rect == frames[0].rect, "n=\(n)")
            }
        }
        #expect(LayoutEngine.optionIDs(posture: .book, feedCount: 3) == ["book.oneLeftTwoRight", "book.perScreen", "book.across"])
        #expect(LayoutEngine.optionIDs(posture: .book, feedCount: 4) == ["book.twoPerScreen", "book.perScreen", "book.across"])
        #expect(LayoutEngine.usableOptionIDs(screen: s, foldFrame: f, posture: .book, feedCount: 3) == ["book.oneLeftTwoRight", "book.perScreen", "book.across"])
        #expect(LayoutEngine.usableOptionIDs(screen: s, foldFrame: f, posture: .book, feedCount: 4) == ["book.twoPerScreen", "book.perScreen", "book.across"])
        // Defaults unchanged.
        #expect(LayoutEngine.frames(screen: s, foldFrame: f, posture: .book, feedCount: 4, optionID: nil).filter(\.visible).count == 4)
    }

    @Test func wrongOrientationOrOutsideFoldBehavesAsFlat() {
        let screen = CGSize(width: 951, height: 669)
        let horizontal = CGRect(x: 0, y: 314, width: 951, height: 40)
        let vertical = CGRect(x: 456, y: 0, width: 40, height: 669)
        let outside = CGRect(x: 4000, y: 0, width: 40, height: 669)
        for n in 1...4 {
            let flat = LayoutEngine.frames(screen: screen, foldFrame: nil, posture: .flat, feedCount: n, optionID: nil)
            #expect(LayoutEngine.frames(screen: screen, foldFrame: horizontal, posture: .book, feedCount: n, optionID: nil) == flat)
            #expect(LayoutEngine.frames(screen: screen, foldFrame: outside, posture: .book, feedCount: n, optionID: nil) == flat)
            #expect(LayoutEngine.frames(screen: screen, foldFrame: vertical, posture: .laptop, feedCount: n, optionID: nil) == flat)
            #expect(LayoutEngine.frames(screen: screen, foldFrame: vertical, posture: .unknown, feedCount: n, optionID: nil) == flat)
        }
    }

    @Test func narrowBookFallsBackToAcrossWithoutEnteringTheFold() {
        let screen = CGSize(width: 400, height: 700)
        let fold = CGRect(x: 180, y: 0, width: 40, height: 700)
        let frames = LayoutEngine.frames(screen: screen, foldFrame: fold, posture: .book, feedCount: 4, optionID: nil)
        #expect(frames.count == 4)
        #expect(frames.filter(\.visible).count == 1)
        #expect(frames[0].rect.width >= 200)
    }
}
