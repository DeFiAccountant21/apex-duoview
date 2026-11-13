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

@Suite struct StartResolvedTests {
    @Test func normalCaseKeepsPosition() {
        #expect(Start.position(60_000).resolved(for: .replay(durationMs: 600_000)) == .position(60_000))
    }

    @Test func positionPastNewDurationClampsToStart() {
        #expect(Start.position(700_000).resolved(for: .replay(durationMs: 600_000)) == .position(0))
        #expect(Start.position(600_000).resolved(for: .replay(durationMs: 600_000)) == .position(0))
        #expect(Start.position(-5).resolved(for: .replay(durationMs: 600_000)) == .position(0))
    }

    @Test func savedReplayNowLiveGoesToLiveEdge() {
        #expect(Start.position(60_000).resolved(for: .live) == .liveEdge)
    }

    @Test func savedLiveNowReplayStartsAtBeginning() {
        #expect(Start.liveEdge.resolved(for: .replay(durationMs: 600_000)) == .position(0))
    }

    @Test func liveStaysLiveAndUnknownLengthKeepsPosition() {
        #expect(Start.liveEdge.resolved(for: .live) == .liveEdge)
        #expect(Start.position(90_000).resolved(for: .replay(durationMs: 0)) == .position(90_000))
    }

    @Test func feedNoLongerListedFallsBackToDefault() {
        let b = WatchBookmark(contentId: 1, title: "T", picturePath: nil, channelId: 9,
                              positionMs: 60_000, durationMs: 600_000, live: false, savedAt: Date(timeIntervalSince1970: 0))
        let p = ResumePlan.make(bookmark: b, availableChannelIds: [nil, 5], defaultChannelId: nil, isLiveNow: false, durationMs: nil)
        #expect(p.channelId == nil)
        #expect(p.start.resolved(for: .replay(durationMs: 600_000)) == .position(60_000))
    }

    // MARK: From the start (Android 0.98: a start given with a live stream must survive it)

    @Test func beginningStaysOnLive() {
        #expect(Start.beginning.resolved(for: .live) == .beginning)
    }

    @Test func beginningOnReplayIsZero() {
        #expect(Start.beginning.resolved(for: .replay(durationMs: 600_000)) == .position(0))
        #expect(Start.beginning.resolved(for: .replay(durationMs: 0)) == .position(0))
    }

    @Test func otherStartsOnLiveStillGoToLiveEdge() {
        #expect(Start.position(60_000).resolved(for: .live) == .liveEdge)
        #expect(Start.liveEdge.resolved(for: .live) == .liveEdge)
    }
}
