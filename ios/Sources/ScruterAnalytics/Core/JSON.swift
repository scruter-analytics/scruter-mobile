import Foundation

/// A small JSON value with a deterministic writer (keys in insertion order) and a strict parser.
///
/// The SDK writes its own JSON rather than going through `Codable`: the wire format uses short keys and tuples
/// (`docs/API.md` §5.3), `Codable` would add generic specialisations to the binary (§3.18 budget), and
/// `JSONSerialization` bridges numbers differently on Linux, where the core is tested.
enum JSON {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object(Fields)

    // MARK: Accessors

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    // Field accessors: one call per use instead of an optional chain at every site (§3.18, binary size).
    func str(_ key: String) -> String? { self[key]?.stringValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func int64(_ key: String) -> Int64? { self[key]?.int64Value }
    func list(_ key: String) -> [JSON]? { self[key]?.arrayValue }
    func flag(_ key: String) -> Bool {
        if case .bool(true)? = self[key] { return true }
        return false
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var int64Value: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e15: return Int64(d)
        default: return nil
        }
    }

    var intValue: Int? { int64Value.map { Int(truncatingIfNeeded: $0) } }

    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    var arrayValue: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: Fields? {
        if case .object(let o) = self { return o }
        return nil
    }

    // MARK: Writing

    /// The compact UTF-8 encoding.
    func encoded() -> Data {
        var out = [UInt8]()
        out.reserveCapacity(256)
        write(into: &out)
        return Data(out)
    }

    func encodedString() -> String {
        String(decoding: encoded(), as: UTF8.self)
    }

    func write(into out: inout [UInt8]) {
        switch self {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .bool(let b):
            out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let i):
            out.append(contentsOf: Array(String(i).utf8))
        case .double(let d):
            out.append(contentsOf: Array(JSON.format(d).utf8))
        case .string(let s):
            JSON.writeString(s, into: &out)
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (i, v) in a.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                v.write(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            var first = true
            for (k, v) in o.items {
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                JSON.writeString(k, into: &out)
                out.append(UInt8(ascii: ":"))
                v.write(into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    static func format(_ d: Double) -> String {
        guard d.isFinite else { return "0" }
        if d.rounded() == d && abs(d) < 1e15 { return String(Int64(d)) + ".0" }
        return String(d)
    }

    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "\""): out.append(contentsOf: [92, 34])
            case UInt8(ascii: "\\"): out.append(contentsOf: [92, 92])
            case 0x0A: out.append(contentsOf: [92, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [92, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [92, UInt8(ascii: "t")])
            case 0..<0x20:
                out.append(contentsOf: [92, UInt8(ascii: "u"), 48, 48, hex[Int(b >> 4)], hex[Int(b & 0xF)]])
            default: out.append(b)
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    // MARK: Parsing

    static func parse(_ data: Data) -> JSON? {
        var p = Parser(bytes: [UInt8](data))
        p.skipSpace()
        guard let v = p.value(depth: 0) else { return nil }
        p.skipSpace()
        return p.i == p.bytes.count ? v : nil
    }

    static func parse(_ s: String) -> JSON? { parse(Text.utf8(s)) }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipSpace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        }

        mutating func literal(_ word: String, _ v: JSON) -> JSON? {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else { return nil }
            i += w.count
            return v
        }

        mutating func value(depth: Int) -> JSON? {
            guard depth < 64, i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "n"): return literal("null", .null)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "\""): return string().map { .string($0) }
            case UInt8(ascii: "["):
                i += 1
                var a = [JSON]()
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                while true {
                    skipSpace()
                    guard let v = value(depth: depth + 1) else { return nil }
                    a.append(v)
                    skipSpace()
                    guard i < bytes.count else { return nil }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                    return nil
                }
            case UInt8(ascii: "{"):
                i += 1
                var o = Fields()
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                while true {
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\""), let k = string() else { return nil }
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                    i += 1
                    skipSpace()
                    guard let v = value(depth: depth + 1) else { return nil }
                    o.items.append((k, v))
                    skipSpace()
                    guard i < bytes.count else { return nil }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                    return nil
                }
            default:
                return number()
            }
        }

        mutating func number() -> JSON? {
            let start = i
            var isDouble = false
            while i < bytes.count {
                let c = bytes[i]
                if (c >= 48 && c <= 57) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+") {
                    i += 1
                } else if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                    isDouble = true
                    i += 1
                } else {
                    break
                }
            }
            guard i > start else { return nil }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if !isDouble, let v = Int64(text) { return .int(v) }
            return Double(text).map { .double($0) }
        }

        mutating func hex4() -> UInt32? {
            guard i + 4 <= bytes.count else { return nil }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[i]
                i += 1
                v <<= 4
                switch c {
                case 48...57: v |= UInt32(c - 48)
                case 97...102: v |= UInt32(c - 87)
                case 65...70: v |= UInt32(c - 55)
                default: return nil
                }
            }
            return v
        }

        mutating func string() -> String? {
            i += 1  // opening quote
            var out = [UInt8]()
            while i < bytes.count {
                let c = bytes[i]
                i += 1
                if c == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
                if c != UInt8(ascii: "\\") { out.append(c); continue }
                guard i < bytes.count else { return nil }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    guard var code = hex4() else { return nil }
                    if code >= 0xD800 && code < 0xDC00 {
                        // A surrogate pair.
                        guard i + 6 <= bytes.count, bytes[i] == 92, bytes[i + 1] == UInt8(ascii: "u") else { return nil }
                        i += 2
                        guard let low = hex4(), low >= 0xDC00 && low < 0xE000 else { return nil }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { return nil }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: return nil
                }
            }
            return nil
        }
    }
}

extension JSON: Equatable {
    static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.double(let x), .double(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)):
            guard x.count == y.count else { return false }
            for i in 0..<x.count where x[i] != y[i] { return false }
            return true
        case (.object(let x), .object(let y)): return x == y
        default: return false
        }
    }
}

/// An object's fields: a small ordered list. Objects hold a few keys; a linear search costs nothing there, and a
/// dictionary per key and value type costs kilobytes of generic specialisations (§3.18).
struct Fields: ExpressibleByDictionaryLiteral, Equatable {
    var items: [(String, JSON)]

    init() { items = [] }
    init(items: [(String, JSON)]) { self.items = items }
    init(dictionaryLiteral elements: (String, JSON)...) { items = elements }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    subscript(key: String) -> JSON? {
        get {
            for (k, v) in items where k == key { return v }
            return nil
        }
        set {
            for i in 0..<items.count where items[i].0 == key {
                if let v = newValue { items[i].1 = v } else { items.remove(at: i) }
                return
            }
            if let v = newValue { items.append((key, v)) }
        }
    }

    /// The same keys with the same values, in any order.
    static func == (a: Fields, b: Fields) -> Bool {
        guard a.count == b.count else { return false }
        for (k, v) in a.items where b[k] != v { return false }
        return true
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int64) { self = .int(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Fields(items: elements)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .double(value) }
}
