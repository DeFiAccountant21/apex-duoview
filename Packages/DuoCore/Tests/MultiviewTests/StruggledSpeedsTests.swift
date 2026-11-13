import Testing
@testable import Multiview

/// Android 0.99.9: the speed that struggled is remembered for the app's run, per number of feeds.
@Suite struct StruggledSpeedsTests {
    @Test func nothingRecordedHoldsNothing() {
        let s = StruggledSpeeds()
        #expect(!s.holds(speed: 2, feedCount: 4))
    }

    @Test func thatSpeedAndFasterHold() {
        var s = StruggledSpeeds()
        s.record(speed: 1.5, feedCount: 4)
        #expect(s.holds(speed: 1.5, feedCount: 4))
        #expect(s.holds(speed: 2, feedCount: 4))
    }

    @Test func slowerSpeedsDoNotHold() {
        var s = StruggledSpeeds()
        s.record(speed: 1.5, feedCount: 4)
        #expect(!s.holds(speed: 1.25, feedCount: 4))
        #expect(!s.holds(speed: 1, feedCount: 4))
        #expect(!s.holds(speed: 0.5, feedCount: 4))
    }

    @Test func keepsTheSlowestThatStruggled() {
        var s = StruggledSpeeds()
        s.record(speed: 1.5, feedCount: 4)
        s.record(speed: 2, feedCount: 4)
        #expect(s.holds(speed: 1.5, feedCount: 4))
        s.record(speed: 1.25, feedCount: 4)
        #expect(s.holds(speed: 1.25, feedCount: 4))
    }

    @Test func isPerNumberOfFeeds() {
        var s = StruggledSpeeds()
        s.record(speed: 1.5, feedCount: 4)
        #expect(!s.holds(speed: 2, feedCount: 3))
        #expect(!s.holds(speed: 2, feedCount: 2))
    }

    @Test func normalSpeedOrOneFeedNeverHolds() {
        var s = StruggledSpeeds()
        s.record(speed: 1, feedCount: 4)
        s.record(speed: 0.75, feedCount: 4)
        #expect(!s.holds(speed: 1, feedCount: 4))
        #expect(!s.holds(speed: 2, feedCount: 4))
        s.record(speed: 1.5, feedCount: 1)
        #expect(!s.holds(speed: 2, feedCount: 1))
    }
}
