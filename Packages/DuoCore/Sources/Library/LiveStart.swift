import Foundation

/// Starting a live session that is already under way: whether to ask "From the start" or
/// "Watch live" first (Android 0.97), and where "From the start" begins (Android 0.98).
public enum LiveStart {
    /// A live session on air longer than this asks before anything plays.
    public static let askAfter: TimeInterval = 60

    /// Whether starting this asks "From the start" or "Watch live". Only live sessions, and only
    /// once they have been on air more than a minute. With no known start (the "Live now" row
    /// carries none) it asks, as Android always does for something on air.
    public static func asks(isLive: Bool, sessionStart: Date?, now: Date) -> Bool {
        guard isLive else { return false }
        guard let sessionStart else { return true }
        return now.timeIntervalSince(sessionStart) > askAfter
    }

    /// Where "From the start" begins, in seconds on the stream's own timeline.
    /// - `seekable`: the item's seekable range (earliest kept moment to the live end).
    /// - `current`, `currentDate`: the item's time now and its program date there, if the stream
    ///   carries one.
    /// - `sessionStart`: when the session began, from the schedule.
    /// The session's start when the stream carries program dates and that moment lies within what
    /// the stream keeps (so a build-up before the session is skipped); otherwise the earliest kept
    /// moment, which is what Android 0.98 seeks to.
    public static func beginning(
        seekable: ClosedRange<Double>, current: Double, currentDate: Date?, sessionStart: Date?
    ) -> Double {
        let earliest = seekable.lowerBound
        guard let sessionStart, let currentDate, current.isFinite else { return earliest }
        let target = current + sessionStart.timeIntervalSince(currentDate)
        guard target.isFinite, seekable.contains(target) else { return earliest }
        return target
    }
}
