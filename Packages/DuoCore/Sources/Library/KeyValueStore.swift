import Foundation

/// Minimal persistence seam so the library can be tested without UserDefaults.
public protocol KeyValueStore: Sendable {
    func data(forKey: String) -> Data?
    func set(_ data: Data?, forKey: String)
}

/// In-memory `KeyValueStore`, for tests and previews.
public final class MemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = data
    }
}
