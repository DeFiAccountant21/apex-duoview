import Foundation

/// A parsed JSON value with lenient accessors: F1 TV's JSON has nulls, missing keys and
/// unexpected types, and none of that should make a whole row fail to parse.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The member for `key`, or `.null` when this isn't an object or the key is missing.
    public subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    /// The element at `index`, or `.null` when this isn't an array or the index is out of range.
    public subscript(index: Int) -> JSONValue {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    /// Strings as they are, numbers as their text, anything else (null included) as "".
    public var string: String {
        switch self {
        case .string(let s): return s
        case .number(let d): return Self.text(d)
        default: return ""
        }
    }

    /// Whole numbers, and strings holding one.
    public var int: Int? {
        switch self {
        case .number(let d):
            guard d.isFinite, d == d.rounded(), abs(d) < 9.0e18 else { return nil }
            return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var array: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }

    /// Booleans, and the strings "true" and "false".
    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s):
            switch s.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var isNull: Bool { self == .null }

    private static func text(_ d: Double) -> String {
        if d.isFinite, d == d.rounded(), abs(d) < 9.0e18 { return String(Int(d)) }
        return String(d)
    }
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
}
