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
        #expect(s.defaultPicks == FeedPick.defaultFour.map { Optional($0) })
        #expect(s.lastUsed == s.defaultPicks)
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
        s.defaultPicks = [.f1Live, nil, .data]
        s.lastUsed = [.tracker]
        s.resetToDefault()
        #expect(s.lastUsed == [.f1Live, nil, .data])
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

    @Test func fewerFeedsDefaultsToAsk() {
        let (s, mem) = Self.make()
        #expect(s.fewerFeeds == .ask)
        s.fewerFeeds = .keepSpots
        #expect(MultiviewStore(store: mem).fewerFeeds == .keepSpots)
    }

    @Test func corruptDataFallsBackToStartingValues() {
        let mem = MemoryStore()
        for k in ["multiview.defaults", "multiview.lastUsed", "multiview.presets", "multiview.layouts", "multiview.fewerFeeds"] {
            mem.set(Data("garbage".utf8), forKey: k)
        }
        let s = MultiviewStore(store: mem)
        #expect(s.defaultPicks == FeedPick.defaultFour.map { Optional($0) })
        #expect(s.lastUsed == s.defaultPicks)
        #expect(s.presets.isEmpty)
        #expect(s.layoutChoice(for: LayoutKey(posture: .book, feedCount: 4)) == nil)
        #expect(s.fewerFeeds == .ask)
    }

    @Test func feedPickCodableRoundTrip() throws {
        let picks: [FeedPick?] = [.worldFeed, .f1Live, .tracker, .data, .onboard(lastName: "Pérez"), .other(title: "Pit Lane"), nil]
        let data = try JSONEncoder().encode(picks)
        #expect(try JSONDecoder().decode([FeedPick?].self, from: data) == picks)
    }
}
