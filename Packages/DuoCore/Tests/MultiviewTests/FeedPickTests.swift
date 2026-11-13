import Testing
import F1TV
@testable import Multiview

@Suite struct FeedPickTests {
    static let channels: [Channel] = [
        Channel(id: 1033, isDefault: true, title: "F1 LIVE"),
        Channel(id: 1025, title: "INTERNATIONAL"),
        Channel(id: 1003, title: "TRACKER"),
        Channel(id: 1004, title: "DATA"),
        Channel(id: 1016, isOnboard: true, title: "NORRIS", racingNumber: 1, driverLastName: "Norris"),
        Channel(id: 1009, isOnboard: true, title: "VERSTAPPEN", racingNumber: 3, driverLastName: "Verstappen"),
    ]

    @Test func classifiesSaoPauloFeeds() {
        let c = Self.channels
        #expect(FeedPick(c[1]) == .worldFeed)
        #expect(FeedPick(c[0]) == .f1Live)
        #expect(FeedPick(c[2]) == .tracker)
        #expect(FeedPick(c[3]) == .data)
        #expect(FeedPick(c[4]) == .onboard(lastName: "Norris"))
    }

    @Test func defaultFourResolvesInOrder() {
        let r = FeedPick.resolve(FeedPick.defaultFour, in: Self.channels)
        #expect(r.map { $0?.id } == [1025, 1033, 1003, 1004])
    }

    @Test func onboardMatchesByNameNotNumber() {
        var c = Self.channels
        c[4].racingNumber = 4
        let r = FeedPick.resolve([.onboard(lastName: "norris")], in: c)
        #expect(r.map { $0?.id } == [1016])
        #expect(FeedPick.onboard(lastName: "Pérez").matches(Channel(id: 1, isOnboard: true, driverLastName: "PEREZ")))
    }

    @Test func missingPickIsNil() {
        #expect(FeedPick.resolve([.onboard(lastName: "Senna")], in: Self.channels).map { $0?.id } == [nil])
        let noLive = Array(Self.channels.dropFirst())
        #expect(FeedPick.resolve([.f1Live], in: noLive).map { $0?.id } == [nil])
    }

    @Test func sameFeedNeverTwice() {
        let r = FeedPick.resolve([.worldFeed, .worldFeed], in: Self.channels)
        #expect(r.map { $0?.id } == [1025, nil])
    }

    @Test func nilIdChannelsAreNeverUsed() {
        let r = FeedPick.resolve([.data, nil], in: [Channel(id: nil, title: "DATA")])
        #expect(r.map { $0?.id } == [nil, nil])
    }
}
