import Testing
import Foundation
@testable import Library

@Suite struct ResumePlanTests {
    func bookmark(channel: Int? = 5, pos: Int64 = 60_000, live: Bool = false) -> WatchBookmark {
        WatchBookmark(contentId: 1, title: "T", picturePath: nil, channelId: channel,
                      positionMs: pos, durationMs: 600_000, live: live, savedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func savedChannelAvailableKeepsChannelAndPosition() {
        let p = ResumePlan.make(bookmark: bookmark(), availableChannelIds: [nil, 5, 6], defaultChannelId: nil, isLiveNow: false, durationMs: 600_000)
        #expect(p == ResumePlan(channelId: 5, start: .position(60_000)))
    }

    @Test func savedChannelGoneUsesDefault() {
        let p = ResumePlan.make(bookmark: bookmark(), availableChannelIds: [nil, 6], defaultChannelId: 6, isLiveNow: false, durationMs: 600_000)
        #expect(p == ResumePlan(channelId: 6, start: .position(60_000)))
    }

    @Test func positionPastDurationClampsToZero() {
        let p = ResumePlan.make(bookmark: bookmark(pos: 700_000), availableChannelIds: [5], defaultChannelId: nil, isLiveNow: false, durationMs: 600_000)
        #expect(p.start == .position(0))
        let eq = ResumePlan.make(bookmark: bookmark(pos: 600_000), availableChannelIds: [5], defaultChannelId: nil, isLiveNow: false, durationMs: 600_000)
        #expect(eq.start == .position(0))
    }

    @Test func unknownDurationKeepsPosition() {
        let p = ResumePlan.make(bookmark: bookmark(pos: 700_000), availableChannelIds: [5], defaultChannelId: nil, isLiveNow: false, durationMs: nil)
        #expect(p.start == .position(700_000))
        let z = ResumePlan.make(bookmark: bookmark(pos: 700_000), availableChannelIds: [5], defaultChannelId: nil, isLiveNow: false, durationMs: 0)
        #expect(z.start == .position(700_000))
    }

    @Test func negativePositionClampsToZero() {
        let p = ResumePlan.make(bookmark: bookmark(pos: -5), availableChannelIds: [5], defaultChannelId: nil, isLiveNow: false, durationMs: nil)
        #expect(p.start == .position(0))
    }

    @Test func liveNowGoesToLiveEdge() {
        let p = ResumePlan.make(bookmark: bookmark(pos: 700_000), availableChannelIds: [5], defaultChannelId: nil, isLiveNow: true, durationMs: 600_000)
        #expect(p.start == .liveEdge)
        #expect(p.channelId == 5)
    }

    @Test func bookmarkLiveGoesToLiveEdge() {
        let p = ResumePlan.make(bookmark: bookmark(live: true), availableChannelIds: [5], defaultChannelId: nil, isLiveNow: false, durationMs: 600_000)
        #expect(p.start == .liveEdge)
    }

    @Test func nilChannelAvailableStaysNil() {
        let p = ResumePlan.make(bookmark: bookmark(channel: nil), availableChannelIds: [nil, 6], defaultChannelId: 6, isLiveNow: false, durationMs: 600_000)
        #expect(p.channelId == nil)
    }

    @Test func nilChannelNotAvailableUsesDefault() {
        let p = ResumePlan.make(bookmark: bookmark(channel: nil), availableChannelIds: [6], defaultChannelId: 6, isLiveNow: false, durationMs: 600_000)
        #expect(p.channelId == 6)
    }
}
