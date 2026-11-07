import Foundation

/// The cumulative state of a session (`c` and `pv` of a batch's session, docs/API.md §5.3).
struct SessionState: Equatable {
    var sv = 0
    var ev = 0
    var dur = 0
    var en = ""
    var ex = ""
    /// Per currency, in minor units.
    var rev = Fields()
    var cr = 0
    var anr = 0
    var last: Int64 = 0

    var json: JSON {
        .object([
            "sv": .int(Int64(min(sv, 100_000))), "ev": .int(Int64(min(ev, 100_000))),
            "dur": .int(Int64(max(0, min(dur, 86_400)))), "en": .string(en), "ex": .string(ex),
            "rev": .object(rev), "cr": .int(Int64(cr)), "anr": .int(Int64(min(anr, 1000))),
            "last": .int(last),
        ])
    }

    init() {}

    init?(json: JSON) {
        guard let sv = json.int("sv"), let ev = json.int("ev"), let dur = json.int("dur"),
            let last = json.int64("last")
        else { return nil }
        self.sv = sv
        self.ev = ev
        self.dur = dur
        self.last = last
        en = json.str("en") ?? ""
        ex = json.str("ex") ?? ""
        rev = json["rev"]?.objectValue ?? Fields()
        cr = json.int("cr") ?? 0
        anr = json.int("anr") ?? 0
    }
}

/// How the session's app was opened (`o`, docs/MOBILE.md §3.13).
struct Opening {
    /// `icon`, `notification`, `link`, `widget`, `shortcut` or `other`.
    var kind = "icon"
    var url = ""
    var referrer = ""

    var json: JSON {
        var o: Fields = ["k": .string(kind)]
        if !url.isEmpty { o["u"] = .string(url) }
        if !referrer.isEmpty { o["r"] = .string(referrer) }
        return .object(o)
    }

    init(kind: String = "icon", url: String = "", referrer: String = "") {
        self.kind = kind
        self.url = url
        self.referrer = referrer
    }

    init(json: JSON?) {
        kind = json?.str("k") ?? "icon"
        url = json?.str("u") ?? ""
        referrer = json?.str("r") ?? ""
    }
}

/// A session the SDK owns (docs/MOBILE.md §3.2): kept in memory and in its private storage until every state of it is
/// acknowledged and it has ended (and, for crash attribution, while it is younger than 48 hours).
final class Session {
    let id: String
    let daily: String
    let start: Int64
    var installDay: String?
    var firstAfterInstall: Bool
    var dims: Fields
    var opening: Opening
    /// The install source (`ins`), sent once.
    var installSource: JSON?
    var current = SessionState()
    var acked: SessionState?
    var ackedQ = 0
    /// In the Advanced analytics sample (`id mod 100 < aa`).
    var analysed: Bool
    var ended = false
    /// The process died with the session open: decided at the next launch (crash attribution).
    var diedOpen = false
    /// The app went to the background at (ms); nil while in the foreground.
    var backgroundAt: Int64?
    /// Foreground since (ms), for `dur`; nil in the background.
    var foregroundSince: Int64?
    /// Breadcrumbs and screen kept for a crash that MetricKit reports later.
    var screen = ""
    var breadcrumbs: [Breadcrumb] = []

    init(
        id: String, daily: String, start: Int64, installDay: String?, firstAfterInstall: Bool, dims: Fields,
        opening: Opening, analysed: Bool
    ) {
        self.id = id
        self.daily = daily
        self.start = start
        self.installDay = installDay
        self.firstAfterInstall = firstAfterInstall
        self.dims = dims
        self.opening = opening
        self.analysed = analysed
        current.last = start
    }

    /// The state as it would be sent at `now`: the running foreground time included.
    func snapshot(now: Int64) -> SessionState {
        var s = current
        if let since = foregroundSince, now > since {
            s.dur = min(86_400, current.dur + Int((now - since) / 1000))
            s.last = max(s.last, now)
        }
        return s
    }

    /// Folds the running foreground time into `dur`.
    func settleForeground(now: Int64) {
        if let since = foregroundSince, now > since {
            let whole = (now - since) / 1000
            current.dur = min(86_400, current.dur + Int(whole))
            foregroundSince = since + whole * 1000
            current.last = max(current.last, now)
        }
    }

    /// The batch's session object for state number `q`.
    func wire(q: Int, state: SessionState) -> JSON {
        var o = dims
        o["id"] = .string(id)
        o["d"] = .string(daily)
        o["q"] = .int(Int64(q))
        o["st"] = .int(start)
        if let i = installDay { o["i"] = .string(i) }
        o["n"] = .int(firstAfterInstall ? 1 : 0)
        o["o"] = opening.json
        if let ins = installSource { o["ins"] = ins }
        o["c"] = state.json
        if q > 1, let pv = acked { o["pv"] = pv.json }
        return .object(o)
    }

    var persisted: JSON {
        var o: Fields = [
            "id": .string(id), "d": .string(daily), "st": .int(start), "n": .bool(firstAfterInstall),
            "dims": .object(dims), "o": opening.json, "c": current.json, "q": .int(Int64(ackedQ)),
            "aa": .bool(analysed), "end": .bool(ended), "died": .bool(diedOpen), "scr": .string(screen),
            "bc": .array(breadcrumbs.map { $0.json }),
        ]
        if let i = installDay { o["i"] = .string(i) }
        if let a = acked { o["pv"] = a.json }
        if let ins = installSource { o["ins"] = ins }
        if let b = backgroundAt { o["bg"] = .int(b) }
        return .object(o)
    }

    static func restore(_ j: JSON) -> Session? {
        guard let id = j.str("id"), let d = j.str("d"), let st = j.int64("st"),
            let c = j["c"].flatMap(SessionState.init(json:))
        else { return nil }
        let s = Session(
            id: id, daily: d, start: st, installDay: j.str("i"),
            firstAfterInstall: j.flag("n"), dims: j["dims"]?.objectValue ?? Fields(), opening: Opening(json: j["o"]),
            analysed: j.flag("aa"))
        s.current = c
        s.acked = j["pv"].flatMap(SessionState.init(json:))
        s.ackedQ = j.int("q") ?? 0
        s.ended = j.flag("end")
        s.diedOpen = j.flag("died")
        s.installSource = j["ins"]
        s.backgroundAt = j.int64("bg")
        s.screen = j.str("scr") ?? ""
        s.breadcrumbs = (j.list("bc") ?? []).compactMap(Breadcrumb.init(json:))
        return s
    }
}

/// A breadcrumb of a crash report: a screen or event name and its time, never a value (docs/MOBILE.md §3.10).
struct Breadcrumb {
    var kind: String
    var name: String
    var time: Int64

    var json: JSON { ["k": .string(kind), "n": .string(name), "t": .int(time)] }

    init(kind: String, name: String, time: Int64) {
        self.kind = kind
        self.name = name
        self.time = time
    }

    init?(json: JSON) {
        guard let k = json.str("k"), let n = json.str("n"), !n.isEmpty else { return nil }
        kind = k == "event" ? "event" : "screen"
        name = Text.cut(n, max: 120)
        time = json.int64("t") ?? 0
    }
}
