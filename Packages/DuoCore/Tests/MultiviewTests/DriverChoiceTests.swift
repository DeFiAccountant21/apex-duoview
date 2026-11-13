import Foundation
import Testing
import F1TV
@testable import Multiview

@Suite struct DriverChoiceTests {
    @Test func newestRaceIsLatestStartNotListOrder() {
        let older = CatalogItem(contentId: 1, title: "Popular", year: 2021, start: Date(timeIntervalSince1970: 1_600_000_000))
        let newest = CatalogItem(contentId: 2, title: "Newest", year: 2026, start: Date(timeIntervalSince1970: 1_790_000_000))
        let middle = CatalogItem(contentId: 3, title: "Middle", year: 2025, start: Date(timeIntervalSince1970: 1_750_000_000))
        #expect(DriverChoice.newestRace([older, newest, middle])?.contentId == 2)
        #expect(DriverChoice.newestRace([]) == nil)
    }

    @Test func newestRaceFallsBackToYear() {
        let a = CatalogItem(contentId: 1, year: 2024)
        let b = CatalogItem(contentId: 2, year: 2026)
        let undated = CatalogItem(contentId: 3)
        #expect(DriverChoice.newestRace([a, undated, b])?.contentId == 2)
        // A start date beats a year alone.
        let dated = CatalogItem(contentId: 4, year: 2020, start: Date(timeIntervalSince1970: 1_000))
        #expect(DriverChoice.newestRace([b, dated])?.contentId == 4)
    }

    @Test func driversAreOnboardsByRacingNumber() {
        let channels: [Channel] = [
            Channel(id: 1033, isDefault: true, title: "F1 LIVE"),
            Channel(id: 1009, isOnboard: true, title: "VERSTAPPEN", racingNumber: 3, driverLastName: "Verstappen"),
            Channel(id: 1003, title: "TRACKER"),
            Channel(id: 1016, isOnboard: true, title: "NORRIS", racingNumber: 1, driverLastName: "Norris"),
            Channel(id: 1020, isOnboard: true, title: "NO NUMBER", driverLastName: "Zed"),
            Channel(id: 1021, isOnboard: true, title: "NO NAME", racingNumber: 2),
            Channel(id: 1022, isOnboard: true, title: "AGAIN", racingNumber: 9, driverLastName: "norris"),
            Channel(id: 1030, isOnboard: true, title: "ALBON", racingNumber: 23, driverLastName: "Albon"),
        ]
        let drivers = DriverChoice.drivers(in: channels)
        #expect(drivers.map(\.driverLastName) == ["Norris", "Verstappen", "Albon", "Zed"])
    }
}
