import Testing
import Foundation
import Library
@testable import Multiview

@Suite struct MultiviewStoreTests {
    static func make() -> (MultiviewStore, MemoryStore) {
        let mem = MemoryStore()
        return (MultiviewStore(store: mem), mem)
    }

    @Test func startsWithDefaultFour() {
        let (s, _) = Self.make()
        #expect(s.defaultPicks == FeedPick.defaults(driver: nil))
        #expect(s.defaultPicks == [.worldFeed, nil, .tracker, .data])
        #expect(s.lastUsed == s.defaultPicks)
    }

    @Test func defaultsUseFavouriteDriver() {
        let (s, _) = Self.make()
        s.favouriteDriver = "Norris"
        #expect(s.favouriteDriver == "Norris")
        #expect(s.defaultPicks == [.worldFeed, .onboard(lastName: "Norris"), .tracker, .data])
        #expect(s.lastUsed == s.defaultPicks)
        s.resetToDefault()
        #expect(s.lastUsed == [.worldFeed, .onboard(lastName: "Norris"), .tracker, .data])
    }

    @Test func noDriverLeavesSecondSpotEmpty() {
        let (s, _) = Self.make()
        #expect(s.favouriteDriver == nil)
        #expect(s.defaultPicks == [.worldFeed, nil, .tracker, .data])
        #expect(!s.defaultPicks.contains(.f1Live))
        s.favouriteDriver = "Norris"
        s.favouriteDriver = nil
        #expect(s.defaultPicks == [.worldFeed, nil, .tracker, .data])
        s.favouriteDriver = "  "
        #expect(s.favouriteDriver == nil)
        #expect(s.defaultPicks[1] == nil)
    }

    @Test func changingDriverChangesDefaults() {
        let mem = MemoryStore()
        let s = MultiviewStore(store: mem)
        s.favouriteDriver = "Norris"
        s.lastUsed = [.data]
        s.favouriteDriver = "Verstappen"
        #expect(s.defaultPicks == [.worldFeed, .onboard(lastName: "Verstappen"), .tracker, .data])
        // Changing the driver leaves a written lastUsed alone; reset brings the new default.
        #expect(s.lastUsed == [.data])
        s.resetToDefault()
        #expect(s.lastUsed == [.worldFeed, .onboard(lastName: "Verstappen"), .tracker, .data])
        #expect(MultiviewStore(store: mem).favouriteDriver == "Verstappen")
    }

    @Test func handSetDefaultsIgnoreDriverChanges() {
        let (s, _) = Self.make()
        s.favouriteDriver = "Norris"
        s.defaultPicks = [.data, .tracker]
        s.favouriteDriver = "Verstappen"
        #expect(s.defaultPicks == [.data, .tracker])
    }

    @Test func driverPromptShownPersists() {
        let mem = MemoryStore()
        let a = MultiviewStore(store: mem)
        #expect(a.driverPromptShown == false)
        a.driverPromptShown = true
        #expect(a.driverPromptShown)
        #expect(MultiviewStore(store: mem).driverPromptShown)
    }

    @Test func lastUsedPersistsAcrossInstances() {
        let mem = MemoryStore()
        let a = MultiviewStore(store: mem)
        a.lastUsed = [.tracker, nil, .onboard(lastName: "Norris")]
        let b = MultiviewStore(store: mem)
        #expect(b.lastUsed == [.tracker, nil, .onboard(lastName: "Norris")])
    }

    @Test func resetToDefaultRestoresDefaults() {
        let (s, _) = Self.make()
        s.lastUsed = [.data]
        s.resetToDefault()
        #expect(s.lastUsed == s.defaultPicks)
    }

    @Test func changingDefaultsChangesReset() {
        let (s, _) = Self.make()
        s.defaultPicks = [.onboard(lastName: "Norris"), nil, .data]
        s.lastUsed = [.tracker]
        s.resetToDefault()
        #expect(s.lastUsed == [.onboard(lastName: "Norris"), nil, .data])
    }

    @Test func lastUsedFollowsDefaultUntilWritten() {
        let (s, _) = Self.make()
        s.defaultPicks = [.data]
        #expect(s.lastUsed == [.data])
    }

    @Test func savesAndRenamesPreset() throws {
        let (s, _) = Self.make()
        let p = try s.savePreset(name: "  Race  ", picks: [.worldFeed, nil], layouts: ["book.2": "book.perScreen"])
        #expect(p.name == "Race")
        #expect(s.presets == [p])
        try s.renamePreset(id: p.id, to: " Quali ")
        #expect(s.presets.first?.name == "Quali")
        try s.renamePreset(id: p.id, to: "QUALI")
        #expect(s.presets.first?.name == "QUALI")
        try s.updatePreset(id: p.id, picks: [.data], layouts: [:])
        #expect(s.presets.first?.picks == [.data])
        #expect(s.presets.first?.name == "QUALI")
        s.deletePreset(id: p.id)
        #expect(s.presets.isEmpty)
        s.deletePreset(id: p.id)
    }

    @Test func presetsPersistAcrossInstances() throws {
        let mem = MemoryStore()
        let p = try MultiviewStore(store: mem).savePreset(name: "A", picks: [.tracker, nil], layouts: ["flat.2": "x"])
        #expect(MultiviewStore(store: mem).presets == [p])
    }

    @Test func ninthPresetIsRefused() throws {
        let (s, _) = Self.make()
        for i in 0..<8 { _ = try s.savePreset(name: "P\(i)", picks: [], layouts: [:]) }
        #expect(throws: PresetError.full) { try s.savePreset(name: "P9", picks: [], layouts: [:]) }
        #expect(s.presets.count == 8)
    }

    @Test func emptyAndWhitespaceNamesRefused() {
        let (s, _) = Self.make()
        #expect(throws: PresetError.emptyName) { try s.savePreset(name: "", picks: [], layouts: [:]) }
        #expect(throws: PresetError.emptyName) { try s.savePreset(name: " \n\t ", picks: [], layouts: [:]) }
    }

    @Test func thirtyOneCharacterNameRefused() throws {
        let (s, _) = Self.make()
        #expect(throws: PresetError.nameTooLong) {
            try s.savePreset(name: String(repeating: "a", count: 31), picks: [], layouts: [:])
        }
        let ok = try s.savePreset(name: " " + String(repeating: "a", count: 30) + " ", picks: [], layouts: [:])
        #expect(ok.name.count == 30)
    }

    @Test func duplicateNameRefusedCaseInsensitive() throws {
        let (s, _) = Self.make()
        let a = try s.savePreset(name: "Race", picks: [], layouts: [:])
        #expect(throws: PresetError.duplicateName) { try s.savePreset(name: "rAcE", picks: [], layouts: [:]) }
        let b = try s.savePreset(name: "Quali", picks: [], layouts: [:])
        #expect(throws: PresetError.duplicateName) { try s.renamePreset(id: b.id, to: "RACE") }
        try s.renamePreset(id: a.id, to: "RACE")
    }

    @Test func renamingMissingPresetIsNotFound() {
        let (s, _) = Self.make()
        #expect(throws: PresetError.notFound) { try s.renamePreset(id: UUID(), to: "X") }
        #expect(throws: PresetError.notFound) { try s.updatePreset(id: UUID(), picks: [], layouts: [:]) }
    }

    @Test func layoutChoiceIsPerPostureAndCount() {
        let (s, mem) = Self.make()
        let book4 = LayoutKey(posture: .book, feedCount: 4)
        #expect(book4.string == "book.4")
        #expect(s.layoutChoice(for: book4) == nil)
        s.setLayoutChoice("book.twoPerScreen", for: book4)
        #expect(s.layoutChoice(for: book4) == "book.twoPerScreen")
        #expect(s.layoutChoice(for: LayoutKey(posture: .book, feedCount: 3)) == nil)
        #expect(s.layoutChoice(for: LayoutKey(posture: .flat, feedCount: 4)) == nil)
        #expect(MultiviewStore(store: mem).layoutChoice(for: book4) == "book.twoPerScreen")
    }

    @Test func clearingLayoutChoiceRestoresDefault() {
        let (s, mem) = Self.make()
        let book4 = LayoutKey(posture: .book, feedCount: 4)
        let flat2 = LayoutKey(posture: .flat, feedCount: 2)
        s.setLayoutChoice("book.across", for: book4)
        s.setLayoutChoice("flat.stacked", for: flat2)
        s.clearLayoutChoice(for: book4)
        #expect(s.layoutChoice(for: book4) == nil)
        #expect(s.layoutChoice(for: flat2) == "flat.stacked")
        #expect(MultiviewStore(store: mem).layoutChoice(for: book4) == nil)
        s.clearLayoutChoice(for: LayoutKey(posture: .laptop, feedCount: 1))
        #expect(s.layoutChoice(for: flat2) == "flat.stacked")
    }

    @Test func fewerFeedsDefaultsToAsk() {
        let (s, mem) = Self.make()
        #expect(s.fewerFeeds == .ask)
        s.fewerFeeds = .keepSpots
        #expect(MultiviewStore(store: mem).fewerFeeds == .keepSpots)
    }

    @Test func corruptDataFallsBackToStartingValues() {
        let mem = MemoryStore()
        for k in ["multiview.defaults", "multiview.lastUsed", "multiview.presets", "multiview.layouts", "multiview.fewerFeeds",
                  "multiview.favouriteDriver", "multiview.driverPromptShown", "multiview.speed"] {
            mem.set(Data("garbage".utf8), forKey: k)
        }
        let s = MultiviewStore(store: mem)
        #expect(s.defaultPicks == FeedPick.defaults(driver: nil))
        #expect(s.favouriteDriver == nil)
        #expect(s.driverPromptShown == false)
        #expect(s.lastUsed == s.defaultPicks)
        #expect(s.presets.isEmpty)
        #expect(s.layoutChoice(for: LayoutKey(posture: .book, feedCount: 4)) == nil)
        #expect(s.fewerFeeds == .ask)
        #expect(s.speed == 1)
    }

    @Test func feedPickCodableRoundTrip() throws {
        let picks: [FeedPick?] = [.worldFeed, .f1Live, .tracker, .data, .onboard(lastName: "Pérez"), .other(title: "Pit Lane"), nil]
        let data = try JSONEncoder().encode(picks)
        #expect(try JSONDecoder().decode([FeedPick?].self, from: data) == picks)
    }

    // MARK: Speed (Android 0.99.5: kept between videos)

    @Test func speedStartsAtNormal() {
        let (s, _) = Self.make()
        #expect(s.speed == 1)
    }

    @Test func speedPersistsAcrossInstances() {
        let (s, mem) = Self.make()
        s.speed = 1.5
        #expect(s.speed == 1.5)
        #expect(MultiviewStore(store: mem).speed == 1.5)
    }

    @Test func speedNotOnOfferReadsAsNormal() {
        let (s, mem) = Self.make()
        s.speed = 1.75
        #expect(s.speed == 1)
        mem.set(try? JSONEncoder().encode(3.0), forKey: "multiview.speed")
        #expect(MultiviewStore(store: mem).speed == 1)
    }
}
