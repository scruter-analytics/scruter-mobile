import Foundation

/// Options of `Scruter.start` (docs/MOBILE.md §3.1).
struct StartOptions {
    var appId: String
    var debugKey: String?
    var debug = false
    var testBuild = false
    var endpoint = URL(string: "https://cdn.scruter.net")!
    var apiEndpoint = URL(string: "https://api.scruter.net")!

    /// The app id is a public site code (`ATMONA02`): upper-case letters, digits, `_` and `-`, ≤ 32 characters.
    static func isValidAppId(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return !u.isEmpty && u.count <= 32
            && u.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 45 }
    }

    static func isValidDebugKey(_ s: String) -> Bool {
        s.hasPrefix("scr_dbg_") && s.utf8.count == 51 && s.utf8.dropFirst(8).allSatisfy(isBase64URL)
    }

    static func isValidRegistrationToken(_ s: String) -> Bool {
        s.hasPrefix("scr_qr_") && s.utf8.count == 39 && s.utf8.dropFirst(7).allSatisfy(isBase64URL)
    }

    static func isBase64URL(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 45 || c == 95
    }
}
