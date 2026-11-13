import Foundation

/// What the player should do to keep a secondary feed in step with the main feed.
public enum SyncAction: Equatable, Sendable {
    case none
    case nudge(rate: Double)
    case seek(by: Double)
}

/// Pure rules for keeping multiview feeds in sync with the main feed.
public enum SyncPolicy {
    /// Offsets within this many seconds are left alone.
    public static let tolerance = 0.1
    /// Offsets up to this many seconds are corrected by changing playback rate; larger ones are seeked.
    public static let seekThreshold = 1.0
    /// Playback-rate change applied while nudging back into sync.
    public static let nudgeFraction = 0.03
    /// Playback speeds the user can pick.
    public static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// - Parameters:
    ///   - offset: this feed's time minus the main feed's, in seconds (positive = ahead). nil when no comparable time exists.
    ///   - baseRate: the playback rate the user chose for this feed.
    /// `.none` means the caller should play at `baseRate`, restoring any earlier nudge.
    /// A nil or non-finite offset also returns `.none`.
    public static func action(offset: Double?, baseRate: Double) -> SyncAction {
        guard let offset, offset.isFinite else { return .none }
        let magnitude = abs(offset)
        if magnitude <= tolerance { return .none }
        if magnitude <= seekThreshold {
            // Ahead: slow down. Behind: speed up.
            let factor = offset > 0 ? 1 - nudgeFraction : 1 + nudgeFraction
            return .nudge(rate: baseRate * factor)
        }
        return .seek(by: -offset)
    }
}

/// Decides when the phone is struggling so that secondary feeds should freeze.
public struct StruggleMonitor: Sendable {
    private static let stallWindow: Double = 30
    private static let stallLimit = 2
    private static let droppedWindow: Double = 10
    private static let droppedFramesPerSecondLimit = 10.0

    private var stalls: [Date] = []
    private var drops: [(frames: Int, at: Date)] = []

    public init() {}

    public mutating func record(stall at: Date) {
        prune(at)
        stalls.append(at)
    }

    /// `seconds` is accepted for the caller's sampling interval; the rate is always averaged over a fixed 10 s window.
    public mutating func record(droppedFrames: Int, over seconds: Double, at: Date) {
        prune(at)
        drops.append((max(0, droppedFrames), at))
    }

    public func shouldFreezeOthers(at: Date) -> Bool {
        let stallCount = stalls.filter { within($0, at, Self.stallWindow) }.count
        if stallCount >= Self.stallLimit { return true }
        let frames = drops
            .filter { within($0.at, at, Self.droppedWindow) }
            .reduce(0) { $0 + $1.frames }
        return Double(frames) / Self.droppedWindow > Self.droppedFramesPerSecondLimit
    }

    public mutating func reset() {
        stalls.removeAll()
        drops.removeAll()
    }

    /// True when `time` lies within the `window` seconds before `at`, inclusive.
    private func within(_ time: Date, _ at: Date, _ window: Double) -> Bool {
        let age = at.timeIntervalSince(time)
        return age >= 0 && age <= window
    }

    private mutating func prune(_ at: Date) {
        stalls.removeAll { at.timeIntervalSince($0) > Self.stallWindow }
        drops.removeAll { at.timeIntervalSince($0.at) > Self.droppedWindow }
    }
}

/// The speeds this phone couldn't keep every feed smooth at, for the app's run (Android 0.99.9):
/// per number of feeds, the slowest above 1× that made the others freeze. Choosing that speed or a
/// faster one with that many feeds goes straight to one picture; a slower one doesn't.
public struct StruggledSpeeds: Sendable {
    private var slowest: [Int: Double] = [:]

    public init() {}

    /// The others froze at `speed` with `feedCount` feeds. Only speeds above 1× with more than one
    /// feed count.
    public mutating func record(speed: Double, feedCount: Int) {
        guard speed > 1, feedCount > 1 else { return }
        slowest[feedCount] = min(slowest[feedCount] ?? speed, speed)
    }

    /// Whether `speed` with `feedCount` feeds should hold the others frozen from the start.
    public func holds(speed: Double, feedCount: Int) -> Bool {
        guard speed > 1, feedCount > 1, let struggled = slowest[feedCount] else { return false }
        return struggled <= speed
    }
}
