import Foundation

/// String rules shared by names, properties, selectors and keys (docs/MOBILE.md §3.3–§3.5).
enum Text {
    /// The UTF-8 bytes of a string (one generic specialisation for the whole SDK).
    static func utf8(_ s: String) -> Data { Data(Array(s.utf8)) }

    /// Trimmed, control characters removed, cut to `max` characters (never in the middle of a character).
    static func clean(_ s: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where u.properties.generalCategory != .control {
            out.append(u)
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut(trimmed, max: max)
    }

    /// Cut to `max` characters, counted as the protocol's validators count them (Unicode scalars).
    static func cut(_ s: String, max: Int) -> String {
        if s.unicodeScalars.count <= max { return s }
        var out = String.UnicodeScalarView()
        for (i, u) in s.unicodeScalars.enumerated() {
            if i >= max { break }
            out.append(u)
        }
        return String(out)
    }

    /// `true` when `name` matches the pattern, `*` standing for any run of characters (the remote configuration's
    /// ignored screens, `xs`). Case-sensitive, like the server.
    static func wildcard(_ pattern: String, matches name: String) -> Bool {
        let p = Array(pattern.unicodeScalars)
        let n = Array(name.unicodeScalars)
        var pi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if pi < p.count, p[pi] != "*", p[pi] == n[ni] {
                pi += 1; ni += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ni; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ni = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

/// Randomness: the SDK's identifiers come from the system's CSPRNG (`SystemRandomNumberGenerator`: `arc4random` on
/// Apple platforms, `getrandom` on Linux), never from anything about the device.
enum Random {
    static func hex(bytes: Int) -> String {
        var g = SystemRandomNumberGenerator()
        var s = ""
        s.reserveCapacity(bytes * 2)
        let digits = Array("0123456789abcdef")
        for _ in 0..<bytes {
            let b = UInt8.random(in: 0...255, using: &g)
            s.append(digits[Int(b >> 4)])
            s.append(digits[Int(b & 0xF)])
        }
        return s
    }

    /// A screen-view number: 1 … 2^53 − 1 (exact in a JavaScript number, docs/API.md §5.3).
    static func screenViewNumber() -> Int64 {
        Int64.random(in: 1...((1 << 53) - 1))
    }

    static func unit() -> Double { Double.random(in: 0..<1) }
}

/// Dates of the app's time zone: the daily id and the install day turn at its midnight (docs/MOBILE.md §2.1).
enum Day {
    static func string(ms: Int64, zone: TimeZone) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        var seconds = Int64((ms / 1000)) + Int64(zone.secondsFromGMT(for: date))
        seconds -= (seconds % 86_400 + 86_400) % 86_400
        // Civil date from a day count (Howard Hinnant's algorithm), proleptic Gregorian.
        let z = seconds / 86_400 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return String(year) + (month < 10 ? "-0" : "-") + String(month) + (day < 10 ? "-0" : "-") + String(day)
    }

    static func zone(_ identifier: String?) -> TimeZone {
        if let id = identifier, let z = TimeZone(identifier: id) { return z }
        return TimeZone.current
    }
}

/// Minor units per ISO 4217 currency (revenue is summed in minor units, docs/API.md §5.3 `rev`).
enum Currency {
    private static let zero = [
        "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF",
        "XPF",
    ]
    private static let three = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]

    static func isValid(_ code: String) -> Bool {
        code.utf8.count == 3 && code.utf8.allSatisfy { $0 >= 65 && $0 <= 90 }
    }

    static func minorUnits(_ amount: Double, currency: String) -> Int64 {
        let factor: Double = zero.contains(currency) ? 1 : three.contains(currency) ? 1000 : 100
        let v = (amount * factor).rounded()
        guard v.isFinite else { return 0 }
        return Int64(max(-1e11, min(1e11, v)))
    }
}
