import Foundation
import Library

/// `KeyValueStore` backed by the app's standard UserDefaults. `UserDefaults.standard` is
/// looked up on each call, so the struct holds no non-Sendable state.
struct UserDefaultsStore: KeyValueStore {
    func data(forKey key: String) -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        if let data {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
