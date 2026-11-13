import SwiftUI

// The only code that touches the iPhone Duo APIs. Declarations come from the iPhoneOS 27.2 SDK
// (spec O3); everything used here is available from iOS 27.1, the deployment target, so there are
// no availability checks.

extension View {
    /// Feeds `state` from the device's hinge and fold. Attach at the root and on full-screen
    /// covers (the root's reader may not see a change while a cover is up): every reader measures
    /// the same full-screen space, and `FoldState` only publishes real changes.
    func foldTracking(_ state: FoldState) -> some View {
        modifier(SystemFoldProvider(state: state))
    }
}

/// Reads the hinge with `onHingeChange` and the fold with
/// `GeometryProxy.reservedRegions(kind: .division)`, and hands both to `FoldState`, which works out
/// the posture.
struct SystemFoldProvider: ViewModifier {
    let state: FoldState

    func body(content: Content) -> some View {
        content
            .background { FoldRegionReader(state: state) }
            .onHingeChange { _, newContext in
                // Called on the main actor, like `.onChange`; `nil` hinge means no hinge.
                state.applySystem(hinge: newContext.hinge.map { HingeReading($0) })
            }
    }
}

/// Reads the first active division region from a GeometryReader.
///
/// Coordinates: the reader ignores the safe area, so it covers the whole screen and its local
/// space has its origin at the screen's top-left corner. The frame is therefore in full-screen root
/// coordinates whether `reservedRegions` reports frames in the proxy's local space or in global
/// space, since the two coincide here. (A view-builder `.background` would otherwise be inset by
/// the safe area.)
///
/// When: it re-reads on every size or rotation change, and on every hinge update. A division region
/// may only become active once the hinge is partially open, with no size change. So the hinge
/// reading is captured by the reader's closure and is part of the sample: each hinge change makes a
/// new sample, whose `onChange` hands over a freshly queried frame.
private struct FoldRegionReader: View {
    let state: FoldState

    var body: some View {
        // Observed here, so this body runs again after each hinge update. Nothing below writes
        // `systemHinge` or `hingeReported`, so there is no update loop.
        let hinge = state.systemHinge
        let reported = state.hingeReported
        GeometryReader { proxy in
            let sample = FoldGeometry(
                foldFrame: Self.divisionFrame(in: proxy),
                size: proxy.size,
                hinge: hinge,
                hingeReported: reported)
            Color.clear
                .onChange(of: sample, initial: true) { _, newSample in
                    state.applySystem(foldFrame: newSample.foldFrame, rootSize: newSample.size)
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private static func divisionFrame(in proxy: GeometryProxy) -> CGRect? {
        proxy.reservedRegions(kind: .division).first(where: { $0.isActive })?.frame
    }
}

/// What the reader saw. The hinge fields are only there so that each hinge update is a new value,
/// which forces a fresh region query even when the frame and size haven't changed.
private struct FoldGeometry: Equatable {
    var foldFrame: CGRect?
    var size: CGSize
    var hinge: HingeReading?
    var hingeReported: Bool
}

extension HingeReading {
    /// Maps SwiftUI's hinge. `DeviceHinge.Status` is a struct with static values, not an enum, so
    /// it is compared with `==` and anything else falls through to `.unknown`.
    init(_ hinge: DeviceHinge) {
        let status: HingeStatus
        if hinge.status == .closed {
            status = .closed
        } else if hinge.status == .partiallyOpen {
            status = .partiallyOpen
        } else if hinge.status == .fullyOpen {
            status = .fullyOpen
        } else {
            status = .unknown
        }
        self.init(status: status, angleDegrees: hinge.angle.degrees)
    }
}
