import Foundation

/// The remote configuration (`GET /m/v1/config`, docs/API.md §5.3, docs/MOBILE.md §3.16).
struct RemoteConfig {
    /// 0: send nothing, keep nothing.
    var on = true
    /// Etag, echoed by batches as `ce` ("" before the first answer).
    var etag = ""
    /// The app's time zone: midnight of the daily id and the install day.
    var timeZone: String?
    /// Advanced analytics sample percent: 0 off, 1–99 sampled, 100 full.
    var aa = 0
    /// Crash reports.
    var crashes = true
    /// Ignored screens (wildcards).
    var ignoredScreens: [String] = []
    /// Team phones may take screen images.
    var teamPhones = false
    /// Seconds before asking again.
    var ttl = 3600
    /// When this copy was fetched (ms); 0 = defaults, never fetched.
    var fetchedAt: Int64 = 0

    /// The defaults before the first answer: collection on, Advanced analytics off, crash reports on.
    static let defaults = RemoteConfig()

    /// Parses an answer; `nil` when it is not a configuration (then the cached copy stays).
    static func parse(_ json: JSON, fetchedAt: Int64) -> RemoteConfig? {
        guard json.int("v") == 1, let on = json.int("on"), let e = json.str("e"), !e.isEmpty
        else { return nil }
        var c = RemoteConfig()
        c.on = on == 1
        c.etag = Text.cut(e, max: 64)
        c.timeZone = json.str("tz")
        c.aa = max(0, min(100, json.int("aa") ?? 0))
        c.crashes = (json.int("cr") ?? 1) == 1
        c.ignoredScreens = (json.list("xs") ?? []).compactMap { $0.stringValue }.prefix(50).map { $0 }
        c.teamPhones = (json.int("tp") ?? 0) == 1
        c.ttl = max(60, min(86_400, json.int("ttl") ?? 3600))
        c.fetchedAt = fetchedAt
        return c
    }

    var json: JSON {
        var o: Fields = [
            "v": 1, "on": .int(on ? 1 : 0), "e": .string(etag), "aa": .int(Int64(aa)), "cr": .int(crashes ? 1 : 0),
            "xs": .array(ignoredScreens.map { .string($0) }), "tp": .int(teamPhones ? 1 : 0), "ttl": .int(Int64(ttl)),
            "fetched_at": .int(fetchedAt),
        ]
        if let tz = timeZone { o["tz"] = .string(tz) }
        return .object(o)
    }

    static func fromCache(_ json: JSON) -> RemoteConfig? {
        parse(json, fetchedAt: json.int64("fetched_at") ?? 0)
    }

    func isStale(now: Int64) -> Bool {
        fetchedAt == 0 || now - fetchedAt >= Int64(ttl) * 1000 || now < fetchedAt
    }

    func ignores(screen: String) -> Bool {
        ignoredScreens.contains { Text.wildcard($0, matches: screen) }
    }

    /// The server's sampling rule: a session collects Advanced analytics when `session_id mod 100 < aa`.
    func samples(session id: String) -> Bool {
        guard aa > 0, let n = UInt64(id, radix: 16) else { return false }
        return Int(n % 100) < aa
    }
}
