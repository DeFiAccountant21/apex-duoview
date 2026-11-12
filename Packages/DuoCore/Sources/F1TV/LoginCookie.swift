import Foundation

/// Reads the subscription token out of whatever the owner pasted: the `login-session`
/// cookie value (raw or URL-encoded JSON, optionally prefixed and quoted) or a bare token.
public enum LoginCookie {
    public static let loginURL = URL(string: "https://account.formula1.com/#/en/login")!

    public static func token(from raw: String) -> String? {
        let quotes = CharacterSet(charactersIn: "\"'")
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: quotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("login-session=") {
            value = String(value.dropFirst("login-session=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // The value itself, then up to two rounds of URL-decoding.
        var candidates = [value]
        var decoded = value
        for _ in 0..<2 {
            guard let next = decoded.removingPercentEncoding, next != decoded else { break }
            decoded = next
            candidates.append(decoded)
        }

        for candidate in candidates {
            guard let json = try? JSONValue.parse(Data(candidate.utf8)) else { continue }
            let token = json["data"]["subscriptionToken"]
            if case .string(let t) = token, !t.isEmpty { return t }
        }

        if candidates.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }) {
            return nil  // Looks like the cookie but has no token.
        }
        if value.isEmpty || value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return nil }
        return value
    }
}
