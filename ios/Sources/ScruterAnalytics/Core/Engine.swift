import Foundation

/// The SDK's engine: sessions, the daily id, the install day, screens, events, analysed screen views, crash reports,
/// the persistent queue, batching and the remote configuration (docs/MOBILE.md §2–§3).
///
/// Runs on one serial queue (the facade's) and never on the main thread; tests drive it directly with a manual
/// scheduler and a fake network. Every input carries its time in ms.
final class Engine {
    static let sessionTimeoutMs: Int64 = 30 * 60 * 1000
    static let maxBatchEvents = 200
    static let maxBatchScreenViews = 20
    static let maxBatchCrashes = 5
    static let maxBatchSessions = 20
    static let maxBatchBytes = 512 * 1024
    static let sendThreshold = 50
    static let sendDelayMs: Int64 = 30_000
    static let firstScreenDelay = 2.0
    static let gzipThreshold = 1024
    static let maxBackoff = 600.0
    static let keepDiedOpenMs: Int64 = 24 * 3600 * 1000

    let env: Environment
    let options: StartOptions
    let queue: PersistentQueue
    private(set) var prefs: Prefs
    private(set) var config: RemoteConfig
    private(set) var sessions: [Session] = []
    private(set) var current: Session?
    private(set) var foreground = false
    private(set) var screenView: ScreenView?
    /// The queue item of the current screen view's last analysed state.
    private var screenItem: Int64?
    private var screenName = ""
    private var breadcrumbs: [Breadcrumb] = []
    private var launchTime: Int64

    // Sending.
    private(set) var inflight: Inflight?
    private var requestInFlight = false
    private var sendTimer: Scheduled?
    private var sendTimerAt: Int64 = .max
    private var attempt = 0
    private var retryAt: Int64 = 0
    private var flushCompletions: [() -> Void] = []
    private var firstScreenSent = false

    // Configuration.
    private var configRequest = false
    private var configTimer: Scheduled?

    let team: Team

    // Hooks to the platform layer (called on the engine's queue).
    var onCrashContext: ((JSON) -> Void)?
    /// The current session's Advanced analytics flag and whether crash reports are on.
    var onCollection: ((_ analysed: Bool, _ crashes: Bool) -> Void)?
    /// A screen appeared that a team phone should capture.
    var onCapture: ((String) -> Void)?
    /// A wrapper that measures its own screens (Flutter): no `ScreenView` here, it is told when one begins.
    var screenListener: ((ScruterBridgeScreen) -> Void)?

    init(env: Environment, options: StartOptions) {
        self.env = env
        self.options = options
        queue = PersistentQueue(store: env.store)
        prefs = Prefs.load(env.store)
        config = env.store.read("config.json").flatMap(JSON.parse).flatMap(RemoteConfig.fromCache) ?? .defaults
        launchTime = env.now()
        team = Team(env: env, options: options)
        if let j = env.store.read("sessions.json").flatMap(JSON.parse)?.arrayValue {
            sessions = j.compactMap(Session.restore)
        }
        inflight = env.store.read("inflight.json").flatMap(JSON.parse).flatMap(Inflight.init(json:))
    }

    // MARK: Start

    /// `Scruter.start`: restores the state, ends the session the previous process left open, sets the install day on
    /// the very first launch and fetches the configuration when stale.
    func start() {
        let now = env.now()
        launchTime = now
        env.log.log("start", options.appId, env.device.buildKind)
        for s in sessions where !s.ended {
            // The process died with this session open (§3.2): it ends here.
            s.settleForeground(now: s.current.last)
            s.foregroundSince = nil
            s.ended = true
            s.diedOpen = s.backgroundAt == nil
        }
        if prefs.optedOut || prefs.ignored {
            env.log.log("nothing is sent:", prefs.optedOut ? "opted out" : "this device is ignored")
            purgeCollected()
            return
        }
        if prefs.firstRun {
            prefs.firstRun = false
            // A fresh install, unless the app's data container is older than a day: then the SDK came with an update
            // and the install day is unknown (never counted as an install).
            let fresh = env.device.containerCreatedMs.map { now - $0 < 24 * 3600 * 1000 } ?? true
            if fresh {
                prefs.installDay = Day.string(ms: now, zone: Day.zone(config.timeZone))
                prefs.firstSessionPending = true
                prefs.installSourcePending = true
            }
            savePrefs()
        }
        forgetStaleDailyId(now: now)
        _ = queue.dropExpired(now: now)
        if inflight.map({ now - $0.created > PersistentQueue.maxAgeMs }) == true { dropInflight() }
        if !config.on {
            purgeCollected()
        }
        fetchConfigIfStale()
        if config.on && (!queue.isEmpty || inflight != nil || sessions.contains(where: { $0.hasUnsent(now: now) })) {
            scheduleSend(after: 1)
        }
        team.start(config: config, device: env.device)
        persistSessions()
        publishCollection()
    }

    // MARK: Lifecycle

    /// The app came to the foreground (or was launched into it).
    func enterForeground() {
        let now = env.now()
        guard !foreground else { return }
        foreground = true
        guard collecting else { return }
        forgetStaleDailyId(now: now)
        if let s = current, !s.ended, let bg = s.backgroundAt, now - bg < Engine.sessionTimeoutMs {
            // Back within 30 minutes: the session goes on.
            s.backgroundAt = nil
            s.foregroundSince = now
            pendingOpening = nil
            s.current.last = max(s.current.last, now)
            screenView?.setForeground(true, now: now)
        } else if let s = current, !s.ended, s.backgroundAt == nil {
            s.foregroundSince = now
        } else {
            startSession(now: now)
        }
        fetchConfigIfStale()
        if !queue.isEmpty { scheduleSend(after: 1) }
        publishContext()
    }

    /// The app went to the background: the running state is folded, the screen view paused, and everything waiting
    /// is sent (the platform keeps the process alive for it).
    func enterBackground(completion: (() -> Void)? = nil) {
        let now = env.now()
        foreground = false
        guard collecting, let s = current else {
            completion?()
            return
        }
        s.settleForeground(now: now)
        s.foregroundSince = nil
        s.backgroundAt = now
        if let v = screenView {
            v.setForeground(false, now: now)
            emitScreenState(final: false, now: now)
        }
        publishContext()
        persistAll()
        flush(completion: completion)
    }

    private func startSession(now: Int64) {
        if let old = current {
            endScreenView(now: now, forward: false)
            old.settleForeground(now: now)
            old.foregroundSince = nil
            old.ended = true
        }
        let id = Random.hex(bytes: 8)
        let daily = dailyId(now: now)
        let first = prefs.firstSessionPending
        if first { prefs.firstSessionPending = false }
        var dims = env.device.sessionDims
        dims["tm"] = .int(team.isActive ? 1 : 0)
        let s = Session(
            id: id, daily: daily, start: now, installDay: prefs.installDay, firstAfterInstall: first, dims: dims,
            opening: now - pendingOpeningAt < 5000 ? pendingOpening ?? Opening() : Opening(),
            analysed: config.samples(session: id))
        pendingOpening = nil
        if prefs.installSourcePending {
            var install: Fields = ["src": .string(env.device.installSource)]
            if let endpoint = env.device.copyEndpoint, !endpoint.isEmpty { install["cp"] = .string(String(endpoint.prefix(300))) }
            s.installSource = .object(install)
        }
        s.foregroundSince = now
        sessions.append(s)
        current = s
        breadcrumbs = []
        savePrefs()
        env.log.log("session started", id, s.analysed ? "(Advanced analytics)" : "")
        publishCollection()
        // The screen still on display opens the new session's first screen view.
        if !screenName.isEmpty {
            let name = screenName
            screenName = ""
            screen(name)
        }
        trimSessions(now: now)
        persistSessions()
    }

    private var pendingOpening: Opening?

    /// How the app was opened: applies to the session that started in the last 5 seconds, else to the next one
    /// starting within 5 seconds (a link handled just before the app comes to the foreground).
    func opened(_ opening: Opening) {
        guard collecting else { return }
        let now = env.now()
        if let s = current, !s.ended, s.backgroundAt == nil, now - s.start < 5000 {
            s.opening = opening
            persistSessions()
        } else {
            pendingOpening = opening
            pendingOpeningAt = now
        }
        env.log.log("opening:", opening.kind)
    }

    private var pendingOpeningAt: Int64 = 0

    // MARK: Daily id and install day

    private func dailyId(now: Int64) -> String {
        let today = Day.string(ms: now, zone: Day.zone(config.timeZone))
        if prefs.dailyDate == today, let d = prefs.dailyId { return d }
        let d = Random.hex(bytes: 16)
        prefs.dailyDate = today
        prefs.dailyId = d
        savePrefs()
        return d
    }

    /// The daily id is forgotten at the app's midnight (§2.1): at the first activity after it (no timer runs in the
    /// background).
    private func forgetStaleDailyId(now: Int64) {
        let today = Day.string(ms: now, zone: Day.zone(config.timeZone))
        if let date = prefs.dailyDate, date != today {
            prefs.dailyDate = nil
            prefs.dailyId = nil
            savePrefs()
        }
    }

    // MARK: Screens and events

    /// A screen view (automatic or explicit).
    /// `forward`: the previous screen was left forward (a push or a presentation, not a back or a dismissal): its
    /// forms with a changed field and no error are sent (§3.9).
    func screen(_ rawName: String, forward: Bool = false) {
        guard collecting, let name = ScreenName.explicit(rawName) else { return }
        let now = env.now()
        ensureSession(now: now)
        guard let s = current else { return }
        endScreenView(now: now, forward: forward)
        screenName = name
        if config.ignores(screen: name) {
            env.log.log("screen ignored by the configuration:", name)
            return
        }
        s.current.sv += 1
        if s.current.en.isEmpty { s.current.en = name }
        s.current.ex = name
        s.current.last = now
        s.screen = name
        addBreadcrumb(Breadcrumb(kind: "screen", name: name, time: now), to: s)
        if screenListener == nil {
            screenView = ScreenView(session: s.id, name: name, start: now, analysed: s.analysed)
        }
        screenItem = nil
        enqueue(.event, s, now, ["s": .string(s.id), "k": "screen", "n": .string(name), "t": .int(now)])
        env.log.log("screen", name)
        if !firstScreenSent && (env.device.buildKind == "debug" || s.firstAfterInstall) {
            firstScreenSent = true
            scheduleSend(after: Engine.firstScreenDelay)
        }
        let capture = team.isActive && config.teamPhones && team.wants(screen: name)
        if let listener = screenListener {
            listener(
                ScruterBridgeScreen(
                    session: s.id, name: name, startMs: now, analysed: s.analysed, capture: capture,
                    maxBytes: team.maxBytes, maxHeight: team.maxHeight))
        } else if capture {
            onCapture?(name)
        }
    }

    /// `screen_end` of a wrapper that measures its own screens.
    func wrapperScreenEnd(session id: String, name: String, engagedMs: Int64, depth: Int) {
        guard collecting, let s = session(id), let n = ScreenName.explicit(name) else { return }
        let now = env.now()
        let ms = max(0, min(86_400_000, engagedMs))
        enqueue(
            .event, s, now,
            ["s": .string(id), "k": "screen_end", "n": .string(n), "t": .int(now), "ms": .int(ms), "sc": .int(Int64(depth))])
    }

    /// An analysed state of a wrapper that measures its own screens: dropped outside the sample.
    func wrapperAnalysed(session id: String, body: JSON) {
        guard collecting, let s = session(id), s.analysed else { return }
        enqueue(.screenView, s, env.now(), body)
    }

    private func endScreenView(now: Int64, forward: Bool) {
        guard let v = screenView, let s = session(v.session) else { return }
        v.advance(to: now)
        v.reacted()
        if forward { v.leftForward(now: now) }
        emitScreenState(final: true, now: now)
        enqueue(.event, s, now, v.endEvent(now: now))
        screenView = nil
        screenItem = nil
    }

    /// The current screen view's latest analysed state, replacing the previous one while it is still unsent.
    private func emitScreenState(final: Bool, now: Int64) {
        guard let v = screenView, v.analysed, v.dirty, v.canEmit(final: final),
            let s = session(v.session)
        else { return }
        let unsent = screenItem.map { id in
            queue.items.contains { $0.id == id } && !(inflight?.items.contains(id) ?? false)
        } ?? false
        let replacing = v.wouldReplace(previousUnsent: unsent)
        let body = v.state(now: now, replacing: replacing)
        if replacing, let id = screenItem {
            queue.replace(id: id, body: body, time: now)
        } else {
            screenItem = enqueue(.screenView, s, now, body)?.id
        }
    }

    /// `Scruter.track`.
    func track(_ rawName: String, props: [String: Any]?, revenue: Double?, currency: String?) {
        guard collecting else { return }
        let name = Text.clean(rawName, max: 120)
        guard !name.isEmpty else {
            env.log.log("event without a name: ignored")
            return
        }
        let now = env.now()
        ensureSession(now: now)
        guard let s = current else { return }
        var e: Fields = ["s": .string(s.id), "k": "event", "n": .string(name), "t": .int(now)]
        if let props = props, !props.isEmpty {
            var p = Fields()
            for (key, value) in props {
                guard p.count < 30 else {
                    env.log.log("more than 30 properties, the rest dropped:", name)
                    break
                }
                let k = Text.clean(key, max: 300)
                guard !k.isEmpty, let v = Engine.propertyValue(value) else { continue }
                p[k] = v
            }
            if !p.isEmpty { e["p"] = .object(p) }
        }
        if let amount = revenue {
            if let c = currency?.uppercased(), Currency.isValid(c), amount.isFinite {
                e["$"] = ["a": .double(amount), "c": .string(c)]
                if s.current.rev.count < 10 || s.current.rev[c] != nil {
                    let total = s.current.rev[c]?.int64Value ?? 0
                    s.current.rev[c] = .int(total + Currency.minorUnits(amount, currency: c))
                }
            } else {
                env.log.log("revenue without a valid ISO 4217 currency is not recorded:", name)
            }
        }
        s.current.ev += 1
        s.current.last = now
        addBreadcrumb(Breadcrumb(kind: "event", name: name, time: now), to: s)
        enqueue(.event, s, now, .object(e))
        if env.device.isDebugBuild, let p = e["p"] {
            env.log.log("event", name, p.encodedString())
        } else {
            env.log.log("event", name)
        }
    }

    /// Strings, numbers and booleans, sent as strings (≤ 2 000 characters).
    static func propertyValue(_ v: Any) -> JSON? {
        if let s = v as? String { return .string(Text.clean(s, max: 2000)) }
        if type(of: v) == Bool.self, let b = v as? Bool { return .string(b ? "true" : "false") }
        if let i = v as? Int, type(of: v) == Int.self { return .string(String(i)) }
        if let i = v as? Int64, type(of: v) == Int64.self { return .string(String(i)) }
        if let d = v as? Double, type(of: v) == Double.self { return number(d) }
        if let f = v as? Float, type(of: v) == Float.self { return number(Double(f)) }
        if let n = v as? NSNumber {
            #if canImport(Darwin)
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .string(n.boolValue ? "true" : "false") }
            #endif
            return number(n.doubleValue)
        }
        return nil
    }

    private static func number(_ d: Double) -> JSON? {
        guard d.isFinite else { return nil }
        if d.rounded() == d && abs(d) < 1e15 { return .string(String(Int64(d))) }
        return .string(String(d))
    }

    private func addBreadcrumb(_ b: Breadcrumb, to s: Session) {
        breadcrumbs.append(b)
        if breadcrumbs.count > CrashReport.maxBreadcrumbs { breadcrumbs.removeFirst() }
        s.breadcrumbs = breadcrumbs
        publishContext()
    }

    private func ensureSession(now: Int64) {
        if current == nil || current?.ended == true {
            foreground = true
            startSession(now: now)
        }
    }

    // MARK: Advanced analytics inputs (from the platform layer)

    var analysedScreen: ScreenView? {
        guard collecting, let v = screenView, v.analysed else { return nil }
        return v
    }

    /// Any interaction (a tap, a scroll, a key): engaged time, for every session.
    func interaction() {
        guard collecting else { return }
        screenView?.interaction(at: env.now())
    }

    func scrolled(top: Double, bottom: Double, contentHeight: Int, viewport: (Int, Int), user: Bool) {
        guard collecting, let v = screenView else { return }
        v.viewportWidth = viewport.0
        v.viewportHeight = viewport.1
        v.scrolled(from: top, to: bottom, contentHeight: contentHeight, now: env.now(), userScroll: user)
    }

    func setViewport(width: Int, height: Int) {
        screenView?.viewportWidth = width
        screenView?.viewportHeight = height
    }

    @discardableResult
    func tap(
        selector: String, index: Int, kind: String, x: Int, y: Int, point: (Double, Double), interactive: Bool?
    ) -> Int {
        guard collecting, let v = screenView else { return 0 }
        let r = v.tap(
            selector: selector, index: index, kind: kind, x: x, y: y, point: point, interactive: interactive,
            now: env.now())
        if v.unsentTapCount >= ScreenView.maxTapsPerState { emitScreenState(final: false, now: env.now()) }
        return r.token
    }

    func resolveTap(_ token: Int, dead: Bool) {
        guard token > 0, let v = screenView else { return }
        v.resolveTap(token, dead: dead)
    }

    func formField(form: String?, key: String, type: String, position: Int?) {
        guard let v = analysedScreen else { return }
        v.field(form: form ?? v.name, key: key, type: type, position: position)
    }

    func formFocus(form: String?, key: String) {
        guard let v = analysedScreen else { return }
        v.focus(form: form ?? v.name, key: key, now: env.now())
    }

    func formBlur(form: String?, key: String) {
        guard let v = analysedScreen else { return }
        v.blur(form: form ?? v.name, key: key, now: env.now())
    }

    func formChanged(form: String?, key: String) {
        guard let v = screenView else { return }
        if v.analysed { v.changed(form: form ?? v.name, key: key, now: env.now()) } else { v.interaction(at: env.now()) }
    }

    func fieldError(key: String, kind: ScruterFieldError) {
        analysedScreen?.fieldError(key: key, kind: kind, now: env.now())
    }

    func formSent(_ name: String) {
        guard let v = analysedScreen else { return }
        v.formSent(name, now: env.now())
    }

    // MARK: Crash reports

    /// A crash report of the previous process (ScruterCrash's raw file).
    func crashReported(raw: CrashReport.Raw) {
        guard collecting, config.crashes, let item = CrashReport.item(from: raw) else { return }
        record(crash: item)
    }

    /// A MetricKit diagnostic: attributed to the session that died open nearest before it (a crash), or to the
    /// session running at its time (a hang), else the latest.
    func diagnostic(_ d: CrashReport.Diagnostic, inApp: (String) -> Bool) {
        guard collecting, config.crashes else { return }
        let candidates = sessions.filter { $0.start <= d.time + 2000 && $0 !== current }
        let s: Session?
        if d.kind == "crash" {
            s = candidates.filter { $0.diedOpen && $0.current.cr == 0 }.max { $0.start < $1.start }
        } else {
            s = candidates.filter { $0.current.last + 2000 >= d.time }.max { $0.start < $1.start }
                ?? (current.map { d.time >= $0.start ? $0 : nil } ?? nil)
        }
        guard let session = s,
            let item = CrashReport.item(
                from: d, session: session.id, screen: session.screen, breadcrumbs: session.breadcrumbs, inApp: inApp)
        else { return }
        // De-duplicated against the reports of the crash handlers (± 2 s and the signature, or the same session).
        let known = queue.items.filter { $0.kind == .crash }.map { $0.body } + prefs.recentCrashes
        if known.contains(where: { CrashReport.isDuplicate(item, of: $0) }) { return }
        if d.kind == "crash" && session.current.cr == 1 { return }
        record(crash: item)
    }

    /// A report from a cross-platform layer (JavaScript, Dart) or a non-fatal error.
    func reportError(
        kind: String, src: String, type: String, reason: String, frames: [JSON], debugIds: [String: String],
        images: [JSON] = []
    ) {
        guard collecting, config.crashes else { return }
        let now = env.now()
        ensureSession(now: now)
        guard let s = current, !frames.isEmpty else { return }
        var o: Fields = [
            "s": .string(s.id), "id": .string(Random.hex(bytes: 8)), "t": .int(now), "k": .string(kind),
            "src": .string(src),
            "ex": ["type": .string(Text.cut(type, max: 200)), "reason": .string(Text.clean(reason, max: 200))],
            "th": .array([["c": 1, "m": 1, "f": .array(Array(frames.prefix(CrashReport.maxFrames)))]]),
            "bc": .array(breadcrumbs.map { $0.json }), "scr": .string(s.screen), "fg": .int(foreground ? 1 : 0),
            "up": .int(max(0, now - launchTime)),
        ]
        for k in ["map", "bun", "bld"] {
            if let v = debugIds[k] { o[k] = .string(Text.cut(v, max: 100)) }
        }
        if !images.isEmpty { o["img"] = .array(images) }
        record(crash: .object(o))
        if kind == "crash" {
            s.current.cr = 1
            persistAll()
        }
    }

    private func record(crash item: JSON) {
        guard let sid = item.str("s"), let s = session(sid) else { return }
        if item.str("k") == "anr" {
            s.current.anr += 1
        } else if item.str("k") == "crash" {
            s.current.cr = 1
        }
        let t = item.int64("t") ?? env.now()
        enqueue(.crash, s, t, item)
        prefs.rememberCrash(item)
        savePrefs()
        persistAll()
        env.log.log("crash report queued:", item.str("k") ?? "")
    }

    // MARK: Queue

    @discardableResult
    private func enqueue(_ kind: QueueItem.Kind, _ s: Session, _ time: Int64, _ body: JSON) -> QueueItem? {
        let item = queue.append(kind: kind, session: s.id, time: time, body: body)
        scheduleSave()
        if queue.count >= Engine.sendThreshold {
            scheduleSend(after: 0)
        } else if foreground, let oldest = queue.oldestTime {
            let due = oldest + Engine.sendDelayMs
            scheduleSend(after: Double(max(0, due - env.now())) / 1000)
        }
        return item
    }

    private var saveTimer: Scheduled?

    /// Disk writes are coalesced: one append per second at most.
    private func scheduleSave() {
        guard saveTimer == nil else { return }
        saveTimer = env.scheduler.schedule(after: 1) { [weak self] in
            self?.saveTimer = nil
            self?.persistAll()
        }
    }

    func persistAll() {
        queue.save()
        persistSessions()
    }

    private func persistSessions() {
        env.store.write("sessions.json", JSON.array(sessions.map { $0.persisted }).encoded())
    }

    private func savePrefs() { prefs.save(env.store) }

    /// An ended session is forgotten (its daily id with it) once every state is acknowledged; a session the process
    /// left open is kept up to 24 hours so that MetricKit's report of its crash, delivered at a later launch, can
    /// still name it (docs/MOBILE.md §2.1, §3.10).
    private func trimSessions(now: Int64) {
        var kept = [Session]()
        for s in sessions {
            let finished = s !== current && s.ended && !s.hasUnsent(now: now)
            if finished && (!s.diedOpen || s.current.cr == 1 || now - s.current.last > Engine.keepDiedOpenMs) { continue }
            kept.append(s)
        }
        sessions = kept
        var extra = sessions.count - 40
        if extra > 0 {
            kept = []
            for s in sessions {
                if extra > 0 && s !== current && !s.hasUnsent(now: now) { extra -= 1 } else { kept.append(s) }
            }
            sessions = kept
        }
    }

    // MARK: Sending

    /// Sends everything that waits, batch after batch; `completion` once the queue is empty or a batch failed.
    func flush(completion: (() -> Void)? = nil) {
        if let c = completion { flushCompletions.append(c) }
        guard collecting else {
            finishFlush()
            return
        }
        sendNow(flushing: true)
    }

    private func finishFlush() {
        let c = flushCompletions
        flushCompletions = []
        c.forEach { $0() }
    }

    private func scheduleSend(after seconds: Double) {
        let at = env.now() + Int64(seconds * 1000)
        if sendTimer != nil && sendTimerAt <= at { return }
        sendTimer?.cancel()
        sendTimerAt = at
        sendTimer = env.scheduler.schedule(after: seconds) { [weak self] in
            guard let self = self else { return }
            self.sendTimer = nil
            self.sendTimerAt = .max
            self.sendNow(flushing: false)
        }
    }

    private func sendNow(flushing: Bool) {
        guard collecting, !requestInFlight else {
            if !collecting { finishFlush() }
            return
        }
        let now = env.now()
        if now < retryAt {
            if flushing { finishFlush() }
            scheduleSend(after: Double(retryAt - now) / 1000)
            return
        }
        if inflight == nil {
            if let v = screenView, v.analysed { emitScreenState(final: false, now: now) }
            _ = queue.dropExpired(now: now)
            inflight = buildBatch(now: now)
            guard inflight != nil else {
                finishFlush()
                return
            }
            env.store.write("inflight.json", inflight!.json.encoded())
            queue.save()
        }
        guard let batch = inflight else { return }
        var headers = ["Content-Type": "application/json"]
        var body = batch.body
        if body.count > Engine.gzipThreshold {
            body = env.gzip(body)
            headers["Content-Encoding"] = "gzip"
        }
        let url = options.endpoint.appendingPathComponent("m/v1/batch")
        requestInFlight = true
        env.log.log("batch", batch.id, String(batch.items.count) + " items, " + String(body.count) + " bytes")
        env.http.send(HTTPRequest(method: "POST", url: url, headers: headers, body: body)) { [weak self] response in
            self?.handle(response, for: batch)
        }
    }

    private func handle(_ response: HTTPResponse?, for batch: Inflight) {
        requestInFlight = false
        let status = response?.status ?? 0
        if status == 202 || status == 200 {
            attempt = 0
            retryAt = 0
            commit(batch)
            if let j = response.flatMap({ JSON.parse($0.body) }) {
                if j.int("r") == 1 { fetchConfig() }
                for w in j.list("w") ?? [] { env.log.log("server warning:", w.stringValue ?? "") }
            }
            if collecting && (!queue.isEmpty || !flushCompletions.isEmpty) {
                if queue.count >= Engine.sendThreshold || !flushCompletions.isEmpty || !foreground {
                    if queue.isEmpty { finishFlush() } else { sendNow(flushing: true) }
                } else if let oldest = queue.oldestTime {
                    scheduleSend(after: Double(max(0, oldest + Engine.sendDelayMs - env.now())) / 1000)
                }
            } else {
                finishFlush()
            }
            return
        }
        if status == 0 || status == 408 || status == 429 || status >= 500 {
            // Retry the same batch later: exponential backoff 5 s × 2ⁿ ± 20 %, ≤ 10 minutes, or the server's
            // Retry-After.
            let backoff = min(Engine.maxBackoff, 5 * pow(2, Double(min(attempt, 10))))
            var delay = backoff * (0.8 + 0.4 * Random.unit())
            if let ra = response?.headers["retry-after"].flatMap(Double.init), ra > 0 {
                delay = min(Engine.maxBackoff, ra)
            }
            attempt += 1
            retryAt = env.now() + Int64(delay * 1000)
            env.log.log("batch retried later, status", String(status), String(Int(delay)) + " s")
            finishFlush()
            scheduleSend(after: delay)
            return
        }
        // Another 4xx: the batch cannot be fixed by sending it again. Dropped; sessions keep their acknowledged state.
        env.log.log("batch refused and dropped, status", String(status))
        attempt = 0
        queue.remove(ids: Set(batch.items))
        dropInflight()
        queue.save()
        finishFlush()
        if !queue.isEmpty { scheduleSend(after: 1) }
    }

    private func commit(_ batch: Inflight) {
        queue.remove(ids: Set(batch.items))
        for sent in batch.sessions {
            guard let s = session(sent.id) else { continue }
            if sent.q > s.ackedQ {
                s.acked = sent.state
                s.ackedQ = sent.q
            }
            if sent.ins && s.installSource != nil {
                s.installSource = nil
                prefs.installSourcePending = false
            }
        }
        dropInflight()
        trimSessions(now: env.now())
        queue.save()
        persistSessions()
        savePrefs()
    }

    private func dropInflight() {
        inflight = nil
        env.store.remove("inflight.json")
    }

    /// The next batch: queue items in order within the limits (docs/MOBILE.md §3.15), and the state of every session
    /// they touch plus the sessions with an unacknowledged state.
    func buildBatch(now: Int64) -> Inflight? {
        var included = [String]()
        var bytes = 600
        var events = [JSON](), views = [JSON](), crashes = [JSON](), ids = [Int64]()
        var orphans = Set<Int64>()
        for item in queue.items {
            guard session(item.session) != nil else {
                orphans.insert(item.id)
                continue
            }
            switch item.kind {
            case .event: if events.count >= Engine.maxBatchEvents { continue }
            case .screenView: if views.count >= Engine.maxBatchScreenViews { continue }
            case .crash: if crashes.count >= Engine.maxBatchCrashes { continue }
            }
            let newSession = !included.contains(item.session)
            if newSession && included.count >= Engine.maxBatchSessions { continue }
            if bytes + item.bytes + (newSession ? 900 : 0) > Engine.maxBatchBytes { break }
            if newSession { included.append(item.session) }
            bytes += item.bytes + 1 + (newSession ? 900 : 0)
            ids.append(item.id)
            switch item.kind {
            case .event: events.append(item.body)
            case .screenView: views.append(item.body)
            case .crash: crashes.append(item.body)
            }
        }
        queue.remove(ids: orphans)
        for s in sessions where included.count < Engine.maxBatchSessions && !included.contains(s.id) {
            if s.hasUnsent(now: now) {
                included.append(s.id)
            }
        }
        guard !included.isEmpty else { return nil }
        var sessionJSON = [JSON]()
        var sent = [Inflight.SentState]()
        for id in included {
            guard let s = session(id) else { continue }
            let state = s.snapshot(now: now)
            let q = s.ackedQ + 1
            sessionJSON.append(s.wire(q: q, state: state))
            sent.append(Inflight.SentState(id: id, q: q, state: state, ins: s.installSource != nil))
        }
        var o: Fields = [
            "v": 1, "a": .string(options.appId), "b": .string(Random.hex(bytes: 16)), "t": .int(now),
            "sdk": .string(env.device.sdkName + "/" + env.device.sdkVersion), "ce": .string(config.etag),
            "dbg": .int(options.debug && env.device.isDebugBuild ? 1 : 0), "s": .array(sessionJSON),
        ]
        if !events.isEmpty { o["e"] = .array(events) }
        if !views.isEmpty { o["x"] = .array(views) }
        if !crashes.isEmpty { o["cr"] = .array(crashes) }
        return Inflight(
            id: o["b"]?.stringValue ?? "", body: JSON.object(o).encoded(), items: ids, sessions: sent,
            created: queue.items.first?.time ?? now)
    }

    private func session(_ id: String) -> Session? {
        for s in sessions where s.id == id { return s }
        return nil
    }

    // MARK: Configuration

    private func fetchConfigIfStale() {
        if config.isStale(now: env.now()) { fetchConfig() }
    }

    func fetchConfig() {
        guard !prefs.optedOut, !prefs.ignored, !configRequest else { return }
        var c = URLComponents(url: options.endpoint.appendingPathComponent("m/v1/config"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "a", value: options.appId), URLQueryItem(name: "p", value: env.device.platform),
            URLQueryItem(name: "av", value: env.device.appVersion), URLQueryItem(name: "sv", value: env.device.sdkVersion),
        ]
        guard let url = c.url else { return }
        var headers = [String: String]()
        if config.fetchedAt > 0 && !config.etag.isEmpty { headers["If-None-Match"] = "\"\(config.etag)\"" }
        configRequest = true
        env.http.send(HTTPRequest(method: "GET", url: url, headers: headers, body: nil)) { [weak self] r in
            self?.configAnswered(r)
        }
    }

    private func configAnswered(_ r: HTTPResponse?) {
        configRequest = false
        let now = env.now()
        if r?.status == 304 {
            config.fetchedAt = now
        } else if r?.status == 200, let j = r.flatMap({ JSON.parse($0.body) }), let c = RemoteConfig.parse(j, fetchedAt: now) {
            let wasOn = config.on
            config = c
            env.log.log("configuration", c.etag, (c.on ? "on" : "off") + ", Advanced analytics " + String(c.aa) + "%")
            if !c.on {
                purgeCollected()
            } else if !wasOn, foreground, current == nil || current?.ended == true {
                startSession(now: now)
            }
            team.configure(config: c)
            publishCollection()
        } else {
            // Unreachable or not a configuration: ask again in 5 minutes, keep the copy we have.
            configTimer?.cancel()
            configTimer = env.scheduler.schedule(after: 300) { [weak self] in self?.fetchConfigIfStale() }
            return
        }
        env.store.write("config.json", config.json.encoded())
        configTimer?.cancel()
        configTimer = env.scheduler.schedule(after: Double(config.ttl)) { [weak self] in
            guard let self = self, self.foreground else { return }
            self.fetchConfigIfStale()
        }
    }

    // MARK: Opt-out

    /// `true` while the SDK collects: not opted out, not an ignored device, the configuration on.
    var collecting: Bool { !prefs.optedOut && !prefs.ignored && config.on }

    /// Deletes everything collected and not sent: queue, batch in flight, sessions, screen view.
    private func purgeCollected() {
        queue.clear()
        dropInflight()
        sessions = []
        current = nil
        screenView = nil
        screenItem = nil
        breadcrumbs = []
        sendTimer?.cancel()
        sendTimer = nil
        sendTimerAt = .max
        env.store.remove("sessions.json")
        publishCollection()
        finishFlush()
    }

    /// `Scruter.optOut()`: nothing more is sent, not even the configuration request; the queue, the daily id and the
    /// install day are deleted. Only the flag is kept (docs/MOBILE.md §2.3).
    func optOut() {
        prefs.optedOut = true
        prefs.dailyId = nil
        prefs.dailyDate = nil
        prefs.installDay = nil
        prefs.firstSessionPending = false
        prefs.installSourcePending = false
        prefs.recentCrashes = []
        purgeCollected()
        env.store.remove("config.json")
        savePrefs()
        env.log.log("opted out")
    }

    /// `Scruter.optIn()`: starts as a new install without an install day (the next session is not an install).
    func optIn() {
        guard prefs.optedOut else { return }
        prefs.optedOut = false
        savePrefs()
        env.log.log("opted in")
        resumeAfterSwitch()
    }

    /// `Scruter.ignoreThisDevice()`: the same switch for the team's own test phones.
    func setIgnored(_ ignored: Bool) {
        guard prefs.ignored != ignored else { return }
        prefs.ignored = ignored
        if ignored { purgeCollected() }
        savePrefs()
        env.log.log("this device:", ignored ? "ignored" : "measured again")
        if !ignored { resumeAfterSwitch() }
    }

    private func resumeAfterSwitch() {
        guard collecting else { return }
        fetchConfigIfStale()
        if foreground { startSession(now: env.now()) }
    }

    var isOptedOut: Bool { prefs.optedOut }

    /// The SKAdNetwork / AdAttributionKit conversion window was started (once per install).
    func markSkanDone() {
        prefs.skanDone = true
        savePrefs()
    }
    var isIgnored: Bool { prefs.ignored }

    // MARK: Hooks

    private func publishContext() {
        guard let s = current else { return }
        onCrashContext?([
            "s": .string(s.id), "scr": .string(s.screen), "fg": .int(foreground ? 1 : 0),
            "bc": .array(breadcrumbs.map { $0.json }), "lt": .int(launchTime),
        ])
    }

    private func publishCollection() {
        onCollection?(screenListener == nil && collecting && (current?.analysed ?? false), collecting && config.crashes)
    }

    // MARK: Team phones

    /// `Scruter.handle(url:)`: a team-phone registration link, else an opening.
    @discardableResult
    func handle(url: URL) -> Bool {
        if let token = Links.registrationToken(url, appId: options.appId) {
            // A link can come from anyone: only the person holding the phone makes it a team phone.
            env.confirmTeamPhone { [weak self] yes in
                guard let self = self else { return }
                self.env.scheduler.schedule(after: 0) {
                    if yes {
                        self.team.register(token: token, device: self.env.device)
                    } else {
                        self.env.log.log("team link declined")
                    }
                }
            }
            return true
        }
        if Links.isTeamScheme(url, appId: options.appId) { return true }
        opened(Opening(kind: Links.openingKind(url), url: Links.sanitize(url)))
        return false
    }
}

/// A batch sent and not yet acknowledged: resent byte for byte until it is (docs/MOBILE.md §3.2), kept on disk.
struct Inflight {
    struct SentState {
        var id: String
        var q: Int
        var state: SessionState
        var ins: Bool
    }

    var id: String
    var body: Data
    var items: [Int64]
    var sessions: [SentState]
    var created: Int64

    var json: JSON {
        [
            "id": .string(id), "body": .string(String(decoding: body, as: UTF8.self)), "items": .array(items.map { .int($0) }),
            "created": .int(created),
            "sessions": .array(
                sessions.map { ["id": .string($0.id), "q": .int(Int64($0.q)), "c": $0.state.json, "ins": .bool($0.ins)] }),
        ]
    }

    init(id: String, body: Data, items: [Int64], sessions: [SentState], created: Int64) {
        self.id = id
        self.body = body
        self.items = items
        self.sessions = sessions
        self.created = created
    }

    init?(json: JSON) {
        guard let id = json.str("id"), let body = json.str("body") else { return nil }
        self.id = id
        self.body = Text.utf8(body)
        items = (json.list("items") ?? []).compactMap { $0.int64Value }
        created = json.int64("created") ?? 0
        var s = [SentState]()
        for v in json.list("sessions") ?? [] {
            if let id = v.str("id"), let q = v.int("q"), let c = v["c"].flatMap(SessionState.init(json:)) {
                s.append(SentState(id: id, q: q, state: c, ins: v.flag("ins")))
            }
        }
        sessions = s
    }
}

extension Session {
    func hasUnsent(now: Int64) -> Bool {
        installSource != nil || acked == nil || acked != snapshot(now: now)
    }
}

extension DeviceInfo {
    /// The frozen dimensions of a session (`p`, `bid`, `av`, `ab`, `bk`, `os`, `m`, `f`, `l`).
    var sessionDims: Fields {
        var d: Fields = [
            "p": .string(platform), "av": .string(Text.cut(appVersion.isEmpty ? "0" : appVersion, max: 40)),
            "ab": .string(Text.cut(appBuild, max: 40)), "bk": .string(buildKind),
            "os": .string(Text.cut(os.isEmpty ? "0" : os, max: 20)), "m": .string(Text.cut(model.isEmpty ? "unknown" : model, max: 60)),
            "f": .string(form),
        ]
        if !bundleId.isEmpty { d["bid"] = .string(Text.cut(bundleId, max: 155)) }
        if language.count == 2 { d["l"] = .string(language) }
        return d
    }
}

/// The SDK's own small state (`state.json`).
struct Prefs {
    var firstRun = true
    var optedOut = false
    var ignored = false
    var installDay: String?
    var firstSessionPending = false
    var installSourcePending = false
    var dailyDate: String?
    var dailyId: String?
    var skanDone = false
    /// The last crash reports queued (≤ 10, 48 h): MetricKit's copies of them are dropped.
    var recentCrashes: [JSON] = []

    static func load(_ store: FileStore) -> Prefs {
        var p = Prefs()
        guard let j = store.read("state.json").flatMap(JSON.parse) else { return p }
        p.firstRun = false
        p.optedOut = j.flag("opted_out")
        p.ignored = j.flag("ignored")
        p.installDay = j.str("install_day")
        p.firstSessionPending = j.flag("first_session")
        p.installSourcePending = j.flag("install_source")
        p.dailyDate = j.str("daily_date")
        p.dailyId = j.str("daily_id")
        p.skanDone = j.flag("skan")
        p.recentCrashes = j.list("crashes") ?? []
        return p
    }

    func save(_ store: FileStore) {
        var o: Fields = [
            "opted_out": .bool(optedOut), "ignored": .bool(ignored), "first_session": .bool(firstSessionPending),
            "install_source": .bool(installSourcePending), "skan": .bool(skanDone), "crashes": .array(recentCrashes),
        ]
        if !optedOut {
            if let d = installDay { o["install_day"] = .string(d) }
            if let d = dailyDate { o["daily_date"] = .string(d) }
            if let d = dailyId { o["daily_id"] = .string(d) }
        }
        store.write("state.json", JSON.object(o).encoded())
    }

    /// Keeps only what de-duplication needs: kind, time, threads' frames and images.
    mutating func rememberCrash(_ item: JSON) {
        var slim = Fields()
        for k in ["k", "t", "th", "img"] { slim[k] = item[k] }
        recentCrashes.append(.object(slim))
        if recentCrashes.count > 10 { recentCrashes.removeFirst(recentCrashes.count - 10) }
    }
}
