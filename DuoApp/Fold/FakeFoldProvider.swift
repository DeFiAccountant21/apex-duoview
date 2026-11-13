import CoreGraphics

/// Simulated fold values, set from Settings → Debug, so fold-driven work can be built and tried on
/// any simulator. While it is on, `FoldState` keeps storing what the device reports but publishes
/// these values instead.
@MainActor
struct FakeFoldProvider {
    let state: FoldState

    static let angleRange: ClosedRange<Double> = 0...180
    /// Used when there is no angle to start from (no hinge).
    static let defaultAngle: Double = 90

    var isActive: Bool { state.source == .fake }

    /// Starts from whatever is showing now, so turning it on changes nothing until a value is picked.
    func start() {
        state.useFake(posture: state.posture, angle: clamped(state.hingeAngle ?? Self.defaultAngle))
    }

    func stop() {
        state.useSystem()
    }

    func setPosture(_ posture: Posture) {
        guard isActive else { return }
        state.useFake(posture: posture, angle: clamped(state.hingeAngle ?? Self.defaultAngle))
    }

    func setAngle(_ angle: Double) {
        guard isActive else { return }
        state.useFake(posture: state.posture, angle: clamped(angle))
    }

    private func clamped(_ angle: Double) -> Double {
        min(max(angle, Self.angleRange.lowerBound), Self.angleRange.upperBound)
    }

    /// A stand-in fold: a zero-thickness line through the middle of the tracked view, vertical for
    /// `.book` and horizontal for `.laptop` (matching `FoldState.posture(status:foldFrame:)`).
    /// No fold for the other postures, since the real division region isn't known for them.
    nonisolated static func foldFrame(for posture: Posture, in size: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        switch posture {
        case .book:
            return CGRect(x: size.width / 2, y: 0, width: 0, height: size.height)
        case .laptop:
            return CGRect(x: 0, y: size.height / 2, width: size.width, height: 0)
        case .closed, .flat, .unknown:
            return nil
        }
    }
}
