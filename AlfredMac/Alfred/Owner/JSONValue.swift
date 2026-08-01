import Foundation

// MARK: - JSONValue
//
// A minimal, dependency-free JSON tree. Two jobs, both structural rather than decorative:
//
//  1. Forward compatibility — `OwnerConfig` stashes unknown TOP-LEVEL keys here so a config written
//     by a newer build survives a round-trip through an older one instead of being silently truncated.
//  2. Field-path enumeration — `CloudProjection` walks an encoded config and asserts that EVERY leaf
//     path has an explicit include/exclude decision. Without a generic tree that check would have to
//     be hand-maintained, which is exactly the kind of list that rots and starts leaking fields.

indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Coding

    /// Encoding/decoding containers keyed by arbitrary strings.
    struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        /// Owner configuration has no integer-keyed containers.
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer(), c.decodeNil() {
            self = .null
            return
        }
        if let c = try? decoder.singleValueContainer() {
            if let b = try? c.decode(Bool.self)   { self = .bool(b);   return }
            if let d = try? c.decode(Double.self) { self = .number(d); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
        }
        if var arr = try? decoder.unkeyedContainer() {
            var out: [JSONValue] = []
            while !arr.isAtEnd { out.append(try arr.decode(JSONValue.self)) }
            self = .array(out)
            return
        }
        if let obj = try? decoder.container(keyedBy: DynamicKey.self) {
            var out: [String: JSONValue] = [:]
            for key in obj.allKeys { out[key.stringValue] = try obj.decode(JSONValue.self, forKey: key) }
            self = .object(out)
            return
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath, debugDescription: "Unrecognized JSON value."))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case let .bool(b):
            var c = encoder.singleValueContainer(); try c.encode(b)
        case let .number(n):
            var c = encoder.singleValueContainer()
            // Emit whole numbers as integers so a round-trip doesn't turn 300 into 300.0.
            if n == n.rounded(), abs(n) < 9_007_199_254_740_992 { try c.encode(Int(n)) } else { try c.encode(n) }
        case let .string(s):
            var c = encoder.singleValueContainer(); try c.encode(s)
        case let .array(a):
            var c = encoder.unkeyedContainer()
            for v in a { try c.encode(v) }
        case let .object(o):
            var c = encoder.container(keyedBy: DynamicKey.self)
            for (k, v) in o.sorted(by: { $0.key < $1.key }) {
                guard let key = DynamicKey(stringValue: k) else { continue }
                try c.encode(v, forKey: key)
            }
        }
    }

    // MARK: Convenience

    var objectValue: [String: JSONValue]? { if case let .object(o) = self { return o }; return nil }
    var stringValue: String? { if case let .string(s) = self { return s }; return nil }

    /// Value at a dotted path, e.g. `identity.pronouns.subject`. Array indices are not addressable —
    /// the projection registry treats a whole array as one leaf.
    func value(at path: String) -> JSONValue? {
        path.split(separator: ".").reduce(Optional(self)) { node, part in
            node?.objectValue?[String(part)]
        }
    }

    /// Every addressable path in this tree.
    ///
    /// A path is a "leaf" when it is a scalar, an array, or an EMPTY object — arrays are deliberately
    /// not descended into, because their element shape is governed by the element's own type rather
    /// than by a distinct projection decision per index.
    func leafPaths(prefix: String = "") -> [String] {
        switch self {
        case .object(let fields) where !fields.isEmpty:
            return fields.sorted { $0.key < $1.key }.flatMap { key, value -> [String] in
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                return value.leafPaths(prefix: path)
            }
        default:
            return prefix.isEmpty ? [] : [prefix]
        }
    }

    /// Every string anywhere in the tree — used by leak assertions and secret-shape scanning.
    var allStrings: [String] {
        switch self {
        case let .string(s): return [s]
        case let .array(a):  return a.flatMap(\.allStrings)
        case let .object(o): return o.values.flatMap(\.allStrings)
        default: return []
        }
    }

    /// Build from any `Encodable` using the canonical encoder.
    static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try OwnerConfig.makeEncoder(pretty: false).encode(value)
        return try OwnerConfig.makeDecoder().decode(JSONValue.self, from: data)
    }
}
