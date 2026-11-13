import Foundation
import Library

/// A named set of feeds plus the layouts chosen with them.
public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var picks: [FeedPick?]
    /// Key is `LayoutKey.string`, value is a layout option id.
    public var layouts: [String: String]

    public init(id: UUID = UUID(), name: String, picks: [FeedPick?], layouts: [String: String]) {
        self.id = id
        self.name = name
        self.picks = picks
        self.layouts = layouts
    }
}

/// Identifies where a layout choice applies: a posture and how many feeds are shown.
public struct LayoutKey: Hashable, Sendable {
    public var posture: Posture
    public var feedCount: Int

    public init(posture: Posture, feedCount: Int) {
        self.posture = posture
        self.feedCount = feedCount
    }

    public var string: String { "\(posture.rawValue).\(feedCount)" }
}

/// What to do when fewer feeds are available than the picks want.
public enum FewerFeeds: String, Codable, Sendable {
    case ask, keepSpots, fit
}

public enum PresetError: Error, Equatable {
    case emptyName, nameTooLong, duplicateName, full, notFound
}

/// Persisted multiview memory: default and last-used feeds, named presets, layout choices, the
/// "fewer feeds" preference and the viewer's driver. Stored as JSON; unreadable data falls back to
/// starting values.
public final class MultiviewStore: @unchecked Sendable {
    public static let maxPresets = 8
    public static let maxNameLength = 30

    static let defaultsKey = "multiview.defaults"
    static let lastUsedKey = "multiview.lastUsed"
    static let presetsKey = "multiview.presets"
    static let layoutsKey = "multiview.layouts"
    static let fewerFeedsKey = "multiview.fewerFeeds"
    static let favouriteDriverKey = "multiview.favouriteDriver"
    static let driverPromptShownKey = "multiview.driverPromptShown"

    private let lock = NSLock()
    private let store: any KeyValueStore

    public init(store: any KeyValueStore) {
        self.store = store
    }

    /// Until set by hand, `FeedPick.defaults(driver: favouriteDriver)`, so it follows the driver.
    public var defaultPicks: [FeedPick?] {
        get { lock.lock(); defer { lock.unlock() }; return loadDefaults() }
        set { lock.lock(); defer { lock.unlock() }; write(newValue, Self.defaultsKey) }
    }

    public var lastUsed: [FeedPick?] {
        get {
            lock.lock(); defer { lock.unlock() }
            return read([FeedPick?].self, Self.lastUsedKey) ?? loadDefaults()
        }
        set { lock.lock(); defer { lock.unlock() }; write(newValue, Self.lastUsedKey) }
    }

    public func resetToDefault() {
        lock.lock(); defer { lock.unlock() }
        write(loadDefaults(), Self.lastUsedKey)
    }

    public var presets: [Preset] {
        lock.lock(); defer { lock.unlock() }
        return loadPresets()
    }

    @discardableResult
    public func savePreset(name: String, picks: [FeedPick?], layouts: [String: String]) throws -> Preset {
        lock.lock(); defer { lock.unlock() }
        var items = loadPresets()
        let trimmed = try validated(name, among: items, excluding: nil)
        guard items.count < Self.maxPresets else { throw PresetError.full }
        let preset = Preset(name: trimmed, picks: picks, layouts: layouts)
        items.append(preset)
        write(items, Self.presetsKey)
        return preset
    }

    public func renamePreset(id: UUID, to name: String) throws {
        lock.lock(); defer { lock.unlock() }
        var items = loadPresets()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw PresetError.notFound }
        items[index].name = try validated(name, among: items, excluding: id)
        write(items, Self.presetsKey)
    }

    public func updatePreset(id: UUID, picks: [FeedPick?], layouts: [String: String]) throws {
        lock.lock(); defer { lock.unlock() }
        var items = loadPresets()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw PresetError.notFound }
        items[index].picks = picks
        items[index].layouts = layouts
        write(items, Self.presetsKey)
    }

    public func deletePreset(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        var items = loadPresets()
        items.removeAll { $0.id == id }
        write(items, Self.presetsKey)
    }

    public func layoutChoice(for key: LayoutKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadLayouts()[key.string]
    }

    public func setLayoutChoice(_ choice: String, for key: LayoutKey) {
        lock.lock(); defer { lock.unlock() }
        var all = loadLayouts()
        all[key.string] = choice
        write(all, Self.layoutsKey)
    }

    /// Forgets the layout chosen for this posture and feed count: its default shows again.
    public func clearLayoutChoice(for key: LayoutKey) {
        lock.lock(); defer { lock.unlock() }
        var all = loadLayouts()
        guard all.removeValue(forKey: key.string) != nil else { return }
        write(all, Self.layoutsKey)
    }

    public var fewerFeeds: FewerFeeds {
        get { lock.lock(); defer { lock.unlock() }; return read(FewerFeeds.self, Self.fewerFeedsKey) ?? .ask }
        set { lock.lock(); defer { lock.unlock() }; write(newValue, Self.fewerFeedsKey) }
    }

    /// The viewer's driver (last name), whose onboard is the second default feed. nil for none;
    /// blank names are stored as none.
    public var favouriteDriver: String? {
        get { lock.lock(); defer { lock.unlock() }; return loadFavouriteDriver() }
        set {
            lock.lock(); defer { lock.unlock() }
            let name = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty {
                write(name, Self.favouriteDriverKey)
            } else {
                store.set(nil, forKey: Self.favouriteDriverKey)
            }
        }
    }

    /// The first-run "Pick your driver" sheet was answered (a driver, or Skip).
    public var driverPromptShown: Bool {
        get { lock.lock(); defer { lock.unlock() }; return read(Bool.self, Self.driverPromptShownKey) ?? false }
        set { lock.lock(); defer { lock.unlock() }; write(newValue, Self.driverPromptShownKey) }
    }

    // MARK: - Private (callers hold the lock)

    private func validated(_ name: String, among items: [Preset], excluding id: UUID?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PresetError.emptyName }
        guard trimmed.count <= Self.maxNameLength else { throw PresetError.nameTooLong }
        let clash = items.contains { $0.id != id && $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }
        guard !clash else { throw PresetError.duplicateName }
        return trimmed
    }

    private func loadDefaults() -> [FeedPick?] {
        read([FeedPick?].self, Self.defaultsKey) ?? FeedPick.defaults(driver: loadFavouriteDriver())
    }

    private func loadFavouriteDriver() -> String? {
        guard let name = read(String.self, Self.favouriteDriverKey), !name.isEmpty else { return nil }
        return name
    }

    private func loadPresets() -> [Preset] { read([Preset].self, Self.presetsKey) ?? [] }

    private func loadLayouts() -> [String: String] { read([String: String].self, Self.layoutsKey) ?? [:] }

    private func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ key: String) {
        store.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
