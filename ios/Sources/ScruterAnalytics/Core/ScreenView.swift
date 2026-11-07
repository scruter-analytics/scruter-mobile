import Foundation

/// Error kinds of a form field (`fd` bits, docs/API.md §5.3).
public enum ScruterFieldError: Int {
    case required = 1
    case format = 2
    case refused = 4
    case invalid = 8
}

/// One screen view: its engaged time and scroll depth for every session (`screen_end`), and, in the Advanced analytics
/// sample, its analysed state (`x`): bands, taps, dead and rage taps, forms (docs/MOBILE.md §3.6–§3.9).
///
/// Pure logic, fed by the platform layer: times in ms, positions in points.
final class ScreenView {
    static let bands = 50
    static let engagementWindowMs: Int64 = 60_000
    static let maxTaps = 300
    static let maxTapsPerState = 100
    static let maxStates = 10
    static let maxForms = 10
    static let maxFields = 40

    let session: String
    let number: Int64
    let name: String
    let start: Int64
    let analysed: Bool

    // Viewport and the primary scroll container.
    var viewportWidth = 0
    var viewportHeight = 0
    var contentHeight = 0
    private(set) var hasContainer = false
    private var visible: (Double, Double) = (0, 1)
    private(set) var deepest: Double = 0

    // Time.
    private var lastUpdate: Int64
    private var lastInteraction: Int64
    private var foreground = true
    private(set) var visibleMs: Int64 = 0
    private(set) var engagedMs: Int64 = 0
    private(set) var interacted = false
    private var bandMs = [Int64](repeating: 0, count: ScreenView.bands)

    // Taps.
    private(set) var taps = 0
    private(set) var deadTaps = 0
    private(set) var rageBursts = 0
    private var recorded = 0
    private var recent: [(t: Int64, x: Double, y: Double)] = []
    private var inBurst = false
    private var resolvedTaps: [JSON] = []
    private var waiting: [(token: Int, entry: [JSON])] = []
    private var nextToken = 1

    // Forms.
    private var forms: [Form] = []
    private var lastErrorTap: Int64 = -1
    private var lastTapTime: Int64 = -1

    // States sent (`q`) and the last one still in the queue.
    private(set) var q = 0
    private var lastStateTaps: [JSON] = []
    private(set) var dirty = true

    init(session: String, number: Int64 = Random.screenViewNumber(), name: String, start: Int64, analysed: Bool) {
        self.session = session
        self.number = number
        self.name = name
        self.start = start
        self.analysed = analysed
        lastUpdate = start
        // Reaching a screen is an interaction: the user navigated (or launched the app).
        lastInteraction = start
    }

    // MARK: Time

    /// Accounts the time since the last update: visible, engaged when an interaction happened in the last 60 s, and
    /// for an analysed screen view, the engaged time of each band visible meanwhile (§3.8).
    func advance(to now: Int64) {
        guard foreground, now > lastUpdate else {
            lastUpdate = max(lastUpdate, now)
            return
        }
        visibleMs += now - lastUpdate
        let from = max(lastUpdate, lastInteraction)
        let to = min(now, lastInteraction + ScreenView.engagementWindowMs)
        if to > from {
            let e = to - from
            engagedMs += e
            if analysed {
                for b in visibleBands() { bandMs[b] += e }
            }
            dirty = true
        }
        lastUpdate = now
    }

    func setForeground(_ fg: Bool, now: Int64) {
        if fg == foreground { return }
        if fg {
            foreground = true
            lastUpdate = now
            lastInteraction = now
        } else {
            advance(to: now)
            foreground = false
        }
    }

    func interaction(at now: Int64) {
        advance(to: now)
        lastInteraction = now
        if !interacted {
            interacted = true
            dirty = true
        }
    }

    private func visibleBands() -> Range<Int> {
        let lo = max(0, min(ScreenView.bands - 1, Int((visible.0 * Double(ScreenView.bands)).rounded(.down))))
        let hi = max(lo + 1, min(ScreenView.bands, Int((visible.1 * Double(ScreenView.bands)).rounded(.up))))
        return lo..<hi
    }

    // MARK: Scroll

    /// The primary scroll container's visible part, as fractions of its content (0–1), and its sizes in points.
    /// `userScroll` = the user moved it (an interaction); a layout change is not.
    func scrolled(from top: Double, to bottom: Double, contentHeight: Int, now: Int64, userScroll: Bool) {
        advance(to: now)
        hasContainer = true
        self.contentHeight = max(0, contentHeight)
        let a = max(0, min(1, top))
        let b = max(a, min(1, bottom))
        visible = (a, b)
        if b > deepest {
            deepest = b
            dirty = true
        }
        if userScroll { interaction(at: now) }
    }

    /// The deepest scroll reached in %, rounded to 5; 100 for a screen without a scroll container (§3.7).
    var scrollDepth: Int {
        guard hasContainer else { return 100 }
        let pct = (deepest * 100 / 5).rounded() * 5
        return Int(max(0, min(100, pct)))
    }

    // MARK: Taps

    struct TapResult {
        /// Waiting for the dead-tap verdict (`resolveTap`), or 0.
        var token: Int
        var rage: Bool
    }

    /// A tap at `point` (window points) on an element. `interactive` = step 1 of §3.5 found an interactive target
    /// (then never dead); `nil` = unknown (never dead either).
    @discardableResult
    func tap(
        selector: String, index: Int, kind: String, x: Int, y: Int, point: (Double, Double), interactive: Bool?,
        now: Int64
    ) -> TapResult {
        interaction(at: now)
        lastTapTime = now
        taps += 1
        dirty = true
        // Rage: the third tap within 1 s inside 24 points opens a burst, flagged once (the web's rule).
        recent = recent.filter { now - $0.t < 1000 && abs($0.x - point.0) <= 24 && abs($0.y - point.1) <= 24 }
        if recent.isEmpty { inBurst = false }
        recent.append((now, point.0, point.1))
        let rage = recent.count >= 3 && !inBurst
        if rage {
            inBurst = true
            rageBursts += 1
        }
        guard analysed, recorded < ScreenView.maxTaps else { return TapResult(token: 0, rage: rage) }
        recorded += 1
        let entry: [JSON] = [
            .string(Text.cut(selector, max: 200)), .int(Int64(max(0, min(9999, index)))), .string(kind),
            .int(Int64(max(0, min(100, x)))), .int(Int64(max(0, min(100, y)))), .int(max(0, now - start)),
            .int(rage ? 2 : 0),
        ]
        if interactive == false {
            let token = nextToken
            nextToken += 1
            waiting.append((token, entry))
            return TapResult(token: token, rage: rage)
        }
        resolvedTaps.append(.array(entry))
        return TapResult(token: 0, rage: rage)
    }

    /// The dead-tap verdict, 1 s after a tap on a non-interactive target.
    func resolveTap(_ token: Int, dead: Bool) {
        guard let i = waiting.firstIndex(where: { $0.token == token }) else { return }
        var entry = waiting.remove(at: i).entry
        if dead, case .int(let flags) = entry[6] {
            entry[6] = .int(flags | 1)
            deadTaps += 1
        }
        resolvedTaps.append(.array(entry))
        dirty = true
    }

    /// Something happened after the taps waiting for a verdict: none of them is dead.
    func reacted() {
        while let first = waiting.first { resolveTap(first.token, dead: false) }
    }

    var hasWaitingTaps: Bool { !waiting.isEmpty }
    var unsentTapCount: Int { resolvedTaps.count }

    // MARK: Forms

    final class Form {
        let name: String
        let index: Int
        var started = false
        var sent = false
        var refused = 0
        var firstFocus: Int64?
        var fillMs: Int64 = 0
        var lastField = ""
        var fields: [Field] = []

        init(name: String, index: Int) {
            self.name = name
            self.index = index
        }
    }

    final class Field {
        let key: String
        let type: String
        let position: Int
        var required = false
        var focusCount = 0
        var focusMs: Int64 = 0
        var focusedAt: Int64?
        var errors = 0
        var errorKinds = 0
        var changed = false
        var showingError = false

        init(key: String, type: String, position: Int) {
            self.key = key
            self.type = type
            self.position = position
        }
    }

    @discardableResult
    func form(_ name: String) -> Form? {
        guard analysed else { return nil }
        let n = Text.clean(name, max: 120)
        if let f = forms.first(where: { $0.name == n }) { return f }
        guard forms.count < ScreenView.maxForms else { return nil }
        let f = Form(name: n, index: forms.count)
        forms.append(f)
        dirty = true
        return f
    }

    @discardableResult
    func field(form name: String, key: String, type: String, position: Int? = nil) -> Field? {
        guard let f = form(name) else { return nil }
        let k = Text.clean(key, max: 100)
        guard !k.isEmpty else { return nil }
        if let field = f.fields.first(where: { $0.key == k }) { return field }
        guard f.fields.count < ScreenView.maxFields else { return nil }
        let field = Field(key: k, type: Text.cut(type, max: 30), position: min(255, position ?? f.fields.count))
        f.fields.append(field)
        dirty = true
        return field
    }

    func focus(form: String, key: String, now: Int64) {
        guard let f = self.form(form), let field = field(form: form, key: key, type: "text") else { return }
        interaction(at: now)
        field.focusCount += 1
        field.focusedAt = now
        if !f.started {
            f.started = true
            f.firstFocus = now
        }
        f.lastField = field.key
        dirty = true
    }

    func blur(form: String, key: String, now: Int64) {
        guard let field = field(form: form, key: key, type: "text"), let at = field.focusedAt else { return }
        field.focusMs += max(0, now - at)
        field.focusedAt = nil
        dirty = true
    }

    func changed(form: String, key: String, now: Int64) {
        guard let field = field(form: form, key: key, type: "text") else { return }
        interaction(at: now)
        if !field.changed { dirty = true }
        field.changed = true
        field.showingError = false
    }

    /// An error shown on a field. Errors that follow a tap elsewhere (a send attempt) count one refused attempt.
    func fieldError(key: String, kind: ScruterFieldError, now: Int64) {
        let k = Text.clean(key, max: 100)
        guard let f = forms.first(where: { form in form.fields.contains { $0.key == k } }) ?? forms.first,
            let field = field(form: f.name, key: k, type: "text")
        else { return }
        field.errors += 1
        field.errorKinds |= kind.rawValue
        field.showingError = true
        if lastTapTime >= 0, now - lastTapTime <= 1000, lastErrorTap != lastTapTime, field.focusedAt == nil {
            lastErrorTap = lastTapTime
            f.refused += 1
        }
        dirty = true
    }

    func formSent(_ name: String, now: Int64) {
        guard let f = form(name), !f.sent else { return }
        f.sent = true
        if let first = f.firstFocus { f.fillMs = max(0, now - first) }
        dirty = true
    }

    /// Leaving the screen forward: forms with a changed field and no field showing an error are sent (§3.9).
    func leftForward(now: Int64) {
        for f in forms where !f.sent && f.fields.contains(where: { $0.changed })
            && !f.fields.contains(where: { $0.showingError })
        {
            formSent(f.name, now: now)
        }
    }

    // MARK: Wire

    /// The `screen_end` event (every session).
    func endEvent(now: Int64) -> JSON {
        [
            "s": .string(session), "k": "screen_end", "n": .string(name), "t": .int(now),
            "ms": .int(min(engagedMs, 86_400_000)), "sc": .int(Int64(scrollDepth)),
        ]
    }

    /// Whether another state may be produced: states are numbered 1–10, the 10th kept for the end.
    func canEmit(final: Bool) -> Bool { analysed && (final ? q < ScreenView.maxStates : q < ScreenView.maxStates - 1) }

    /// The next analysed state (`x` item). With `replacing`, the previous state is still unsent in the queue: the new
    /// one takes its number and carries its taps too (the server keeps the highest `q`).
    func state(now: Int64, replacing: Bool) -> JSON {
        advance(to: now)
        var newTaps = Array(resolvedTaps.prefix(ScreenView.maxTapsPerState))
        if replacing && lastStateTaps.count + newTaps.count <= ScreenView.maxTapsPerState {
            newTaps = lastStateTaps + newTaps
        } else {
            q += 1
        }
        resolvedTaps.removeFirst(min(resolvedTaps.count, ScreenView.maxTapsPerState))
        lastStateTaps = newTaps
        dirty = !resolvedTaps.isEmpty
        var o: Fields = [
            "s": .string(session), "k": .int(number), "q": .int(Int64(max(1, q))), "n": .string(name),
            "t": .int(start), "vw": .int(Int64(clamp(viewportWidth, 10_000))),
            "vh": .int(Int64(clamp(viewportHeight, 10_000))), "ch": .int(Int64(clamp(contentHeight, 1_000_000))),
            "sd": .int(Int64(scrollDepth)), "dt": .int(min(visibleMs, 86_400_000)),
            "et": .int(min(engagedMs, 86_400_000)), "ia": .int(interacted ? 1 : 0),
            "cn": .int(Int64(min(taps, 65535))), "cd": .int(Int64(min(deadTaps, 65535))),
            "cr": .int(Int64(min(rageBursts, 65535))), "c": .array(newTaps.map { $0 }),
        ]
        var bands = bandMs.map { min($0, 86_400_000) }
        while let last = bands.last, last == 0 { bands.removeLast() }
        o["at"] = .array(bands.map { .int($0) })
        if !forms.isEmpty { o["f"] = .array(forms.map { formJSON($0, now: now) }) }
        return .object(o)
    }

    /// `true` when this state would be the one taking the previous state's place (see `state`).
    func wouldReplace(previousUnsent: Bool) -> Bool {
        previousUnsent && lastStateTaps.count + min(resolvedTaps.count, ScreenView.maxTapsPerState)
            <= ScreenView.maxTapsPerState
    }

    private func clamp(_ v: Int, _ hi: Int) -> Int { max(0, min(hi, v)) }

    private func formJSON(_ f: Form, now: Int64) -> JSON {
        let fields: [JSON] = f.fields.map { field in
            var focus = field.focusMs
            if let at = field.focusedAt { focus += max(0, now - at) }
            return .array([
                .string(field.key), .string(field.type), .int(field.required ? 1 : 0), .int(Int64(field.position)),
                .int(Int64(min(field.focusCount, 65535))), .int(min(focus, 86_400_000)),
                .int(Int64(min(field.errors, 65535))), .int(Int64(field.errorKinds & 15)), .int(field.changed ? 1 : 0),
            ])
        }
        return [
            "s": .string(f.name), "i": .int(Int64(f.index)), "v": 1, "b": .int(f.started ? 1 : 0),
            "ok": .int(f.sent ? 1 : 0), "rf": .int(Int64(min(f.refused, 65535))), "ms": .int(min(f.fillMs, 86_400_000)),
            "lf": .string(f.lastField), "fd": .array(fields),
        ]
    }
}
