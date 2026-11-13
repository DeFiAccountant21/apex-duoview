import CoreGraphics
import Observation

/// How the phone is folded. `standing` (on its edges) is left out: nothing in the iOS 27.1 SDK tells
/// it apart (spec O3).
enum Posture: String, Sendable, CaseIterable {
    case closed, flat, book, laptop, unknown

    var label: String {
        switch self {
        case .closed: "Closed"
        case .flat: "Flat"
        case .book: "Book"
        case .laptop: "Laptop"
        case .unknown: "Unknown"
        }
    }
}

/// The hinge status, mapped from SwiftUI's `DeviceHinge.Status` so the posture rules don't touch
/// the Duo API. `unknown` catches any status the SDK adds later.
enum HingeStatus: Sendable, Equatable {
    case closed, partiallyOpen, fullyOpen, unknown

    var label: String {
        switch self {
        case .closed: "Closed"
        case .partiallyOpen: "Partially open"
        case .fullyOpen: "Fully open"
        case .unknown: "Unknown status"
        }
    }
}

/// One hinge reading from the system: its status and its angle in degrees.
struct HingeReading: Sendable, Equatable {
    var status: HingeStatus
    var angleDegrees: Double
}

/// The fold, as the rest of the app sees it. `SystemFoldProvider` feeds it from the device;
/// `FakeFoldProvider` replaces those values from Settings → Debug. In beta.1 Settings shows it,
/// and in book posture `RootView` opens Settings on the right-hand screen.
@MainActor
@Observable
final class FoldState {
    enum Source: String, Sendable {
        case system, fake
    }

    private(set) var posture: Posture = .unknown
    /// The first active division region, in full-screen root coordinates: the reader that
    /// queries it ignores the safe area, so its origin is the screen's top-left corner. `nil` when
    /// there is none.
    private(set) var foldFrame: CGRect?
    /// Degrees; `nil` when the device has no hinge or hasn't reported yet (see `hingeReported`).
    private(set) var hingeAngle: Double?
    private(set) var source: Source = .system

    /// The latest system hinge reading, kept while simulating so turning simulation off restores
    /// it at once. Observed on purpose: the region reader re-queries the regions on every change.
    private(set) var systemHinge: HingeReading?
    /// Whether `onHingeChange` has fired at least once. Until it has, a nil `systemHinge` means
    /// "not reported yet", not "no hinge".
    private(set) var hingeReported = false
    @ObservationIgnored private var systemFoldFrame: CGRect?
    /// The full-screen size of the root, in the same space as `foldFrame`; the fake fold frame is
    /// drawn in it.
    private(set) var rootSize: CGSize = .zero

    @ObservationIgnored private var fakePosture: Posture = .unknown
    @ObservationIgnored private var fakeAngle: Double = 90

    init() {}

    // MARK: System input

    /// A hinge update from `onHingeChange`; `nil` means the device has no hinge.
    func applySystem(hinge: HingeReading?) {
        if !hingeReported { hingeReported = true }
        if systemHinge != hinge { systemHinge = hinge }
        if source == .system { publishSystem() }
    }

    /// The division region's frame and the tracked view's size, re-read on every layout or hinge
    /// change.
    func applySystem(foldFrame: CGRect?, rootSize: CGSize) {
        systemFoldFrame = foldFrame
        if self.rootSize != rootSize { self.rootSize = rootSize }
        switch source {
        case .system: publishSystem()
        case .fake: publishFake()
        }
    }

    // MARK: Fake input (FakeFoldProvider)

    /// Switches to (or updates) simulated values. System updates keep arriving but are only stored.
    func useFake(posture: Posture, angle: Double) {
        fakePosture = posture
        fakeAngle = angle
        if source != .fake { source = .fake }
        publishFake()
    }

    /// Back to the device's values, using the latest ones the system reported.
    func useSystem() {
        if source != .system { source = .system }
        publishSystem()
    }

    // MARK: Posture rules

    /// The posture rules, kept pure so they can be tested without a device:
    /// closed → `.closed`; fully open → `.flat`; partially open with a fold taller than wide →
    /// `.book`, wider than tall → `.laptop`. No hinge, an unknown status, or partially open with no
    /// division region (or a square one) → `.unknown`.
    nonisolated static func posture(status: HingeStatus?, foldFrame: CGRect?) -> Posture {
        switch status {
        case .closed?: return .closed
        case .fullyOpen?: return .flat
        case .partiallyOpen?:
            // Compare the sides directly: a fold line can have zero width or height, so
            // `CGRect.isEmpty` would throw it away.
            guard let frame = foldFrame else { return .unknown }
            if frame.height > frame.width { return .book }
            if frame.width > frame.height { return .laptop }
            return .unknown
        case .unknown?, nil:
            return .unknown
        }
    }

    // MARK: Publishing

    private func publishSystem() {
        publish(
            posture: Self.posture(status: systemHinge?.status, foldFrame: systemFoldFrame),
            foldFrame: systemFoldFrame,
            hingeAngle: systemHinge?.angleDegrees)
    }

    private func publishFake() {
        publish(
            posture: fakePosture,
            foldFrame: FakeFoldProvider.foldFrame(for: fakePosture, in: rootSize),
            hingeAngle: fakeAngle)
    }

    /// Writes only real changes, so observers (and the region reader) don't re-run for nothing.
    private func publish(posture: Posture, foldFrame: CGRect?, hingeAngle: Double?) {
        if self.posture != posture { self.posture = posture }
        if self.foldFrame != foldFrame { self.foldFrame = foldFrame }
        if self.hingeAngle != hingeAngle { self.hingeAngle = hingeAngle }
    }
}
