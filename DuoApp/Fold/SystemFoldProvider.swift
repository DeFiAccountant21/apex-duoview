import SwiftUI

// The only code that touches the iPhone Duo APIs. Declarations come from the iPhoneOS 27.2 SDK
// (spec O3); everything used here is available from iOS 27.1, the deployment target, so there are
// no availability checks.

extension View {
    /// Feeds `state` from the device's hinge and fold. Attach once, at the root.
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

/// Reads the first active division region from a GeometryReader that fills the tracked view, so
/// the frame is in that view's coordinates. Re-reads on every size or rotation change, and on every
/// hinge update: a division region may only become active once the hinge is partially open, with
/// no size change to trigger a re-read.
private struct FoldRegionReader: View {
    let state: FoldState

    var body: some View {
        // Observing the system hinge makes this body, and so the reader below, run again after each
        // hinge update. Nothing below writes `systemHinge`, so there is no update loop.
        let _ = state.systemHinge
        GeometryReader { proxy in
            let sample = FoldGeometry(
                foldFrame: Self.divisionFrame(in: proxy),
                size: proxy.size)
            Color.clear
                .onChange(of: sample, initial: true) { _, newSample in
                    state.applySystem(foldFrame: newSample.foldFrame, rootSize: newSample.size)
                }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private static func divisionFrame(in proxy: GeometryProxy) -> CGRect? {
        proxy.reservedRegions(kind: .division).first(where: { $0.isActive })?.frame
    }
}

private struct FoldGeometry: Equatable {
    var foldFrame: CGRect?
    var size: CGSize
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
