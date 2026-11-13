import Testing
import Foundation
@testable import Multiview

@Suite struct SyncPolicyTests {
    /// Extracts the nudge rate, or records an issue if the action is not a nudge.
    static func nudgeRate(_ action: SyncAction) -> Double? {
        if case .nudge(let rate) = action { return rate }
        return nil
    }

    static func seekBy(_ action: SyncAction) -> Double? {
        if case .seek(let by) = action { return by }
        return nil
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func inToleranceDoesNothing() {
        #expect(SyncPolicy.action(offset: 0.1, baseRate: 1) == .none)
        #expect(SyncPolicy.action(offset: -0.1, baseRate: 1) == .none)
        #expect(SyncPolicy.action(offset: 0, baseRate: 1) == .none)
    }

    @Test func aheadIsSlowed() throws {
        let rate = try #require(Self.nudgeRate(SyncPolicy.action(offset: 0.5, baseRate: 1)))
        #expect(abs(rate - 0.97) < 1e-9)
    }

    @Test func behindIsSpedUp() throws {
        let rate = try #require(Self.nudgeRate(SyncPolicy.action(offset: -0.5, baseRate: 2)))
        #expect(abs(rate - 2.06) < 1e-9)
    }

    @Test func oneSecondIsStillANudge() throws {
        let rate = try #require(Self.nudgeRate(SyncPolicy.action(offset: 1.0, baseRate: 1)))
        #expect(abs(rate - 0.97) < 1e-9)
        #expect(Self.seekBy(SyncPolicy.action(offset: 1.0001, baseRate: 1)) != nil)
    }

    @Test func farOffIsSeeked() throws {
        let by = try #require(Self.seekBy(SyncPolicy.action(offset: 2.5, baseRate: 1)))
        #expect(abs(by - (-2.5)) < 1e-9)
    }

    @Test func noTimeDoesNothing() {
        #expect(SyncPolicy.action(offset: nil, baseRate: 1.5) == .none)
    }

    @Test func twoStallsFreeze() {
        var monitor = StruggleMonitor()
        monitor.record(stall: Self.t0)
        #expect(monitor.shouldFreezeOthers(at: Self.t0) == false)
        monitor.record(stall: Self.t0.addingTimeInterval(5))
        #expect(monitor.shouldFreezeOthers(at: Self.t0.addingTimeInterval(5)) == true)
    }

    @Test func oldStallsExpire() {
        var monitor = StruggleMonitor()
        monitor.record(stall: Self.t0)
        monitor.record(stall: Self.t0.addingTimeInterval(31))
        #expect(monitor.shouldFreezeOthers(at: Self.t0.addingTimeInterval(31)) == false)
    }

    @Test func stallExactlyThirtySecondsOldStillCounts() {
        var monitor = StruggleMonitor()
        monitor.record(stall: Self.t0)
        monitor.record(stall: Self.t0.addingTimeInterval(10))
        #expect(monitor.shouldFreezeOthers(at: Self.t0.addingTimeInterval(30)) == true)
        #expect(monitor.shouldFreezeOthers(at: Self.t0.addingTimeInterval(30.5)) == false)
    }

    @Test func droppedFrameRateFreezes() {
        var monitor = StruggleMonitor()
        monitor.record(droppedFrames: 100, over: 1, at: Self.t0)
        #expect(monitor.shouldFreezeOthers(at: Self.t0) == false)
        monitor.record(droppedFrames: 1, over: 1, at: Self.t0.addingTimeInterval(1))
        #expect(monitor.shouldFreezeOthers(at: Self.t0.addingTimeInterval(1)) == true)
    }

    @Test func droppedFramesOutsideTenSecondWindowAreIgnored() {
        var monitor = StruggleMonitor()
        monitor.record(droppedFrames: 200, over: 1, at: Self.t0)
        monitor.record(droppedFrames: 50, over: 1, at: Self.t0.addingTimeInterval(11))
        #expect(monitor.shouldFreezeOthers(at: Self.t0.addingTimeInterval(11)) == false)
    }

    @Test func resetClears() {
        var monitor = StruggleMonitor()
        monitor.record(stall: Self.t0)
        monitor.record(stall: Self.t0)
        monitor.record(droppedFrames: 500, over: 1, at: Self.t0)
        #expect(monitor.shouldFreezeOthers(at: Self.t0) == true)
        monitor.reset()
        #expect(monitor.shouldFreezeOthers(at: Self.t0) == false)
    }

    @Test func speedsAreFixed() {
        #expect(SyncPolicy.speeds == [0.5, 0.75, 1, 1.25, 1.5, 2])
        #expect(SyncPolicy.tolerance == 0.1)
        #expect(SyncPolicy.seekThreshold == 1.0)
        #expect(SyncPolicy.nudgeFraction == 0.03)
    }
}
