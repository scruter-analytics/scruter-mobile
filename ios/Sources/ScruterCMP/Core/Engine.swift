import Foundation

/// The platform side of the engine: the sheet and the main thread (`Apple/`), a recorder in tests.
protocol CMPHost: AnyObject {
    /// Shows the sheet (on the main thread). `anchor`: the view controller the app passed, if any.
    func show(_ model: SheetModel, anchor: AnyObject?)
    /// Closes the sheet without a decision (the CMP was turned off meanwhile).
    func dismiss()
    /// Runs the app's callbacks (on the main thread).
    func deliver(_ block: @escaping () -> Void)
    /// Media and icon of a new configuration, fetched once and kept with it (§2.4).
    func prefetch(_ urls: [String])
}

/// The CMP's logic, platform-free (docs/CMP-MOBILE.md §3): the stored choice, the configuration and its cache, the
/// re-ask rules, the openings and their hits, the decisions and their proofs, the detected SDKs. Everything runs on
/// `queue`; the public API reads `snapshot` under a lock.
final class CMPEngine {
    struct Options {
        var appId: String
        /// Where `GET /m/v1/cmp` and the SDK catalogue are served.
        var base: URL
        var automatic: Bool
    }

    /// What the public API answers synchronously.
    struct Snapshot {
        var state: ScruterCMP.State
        /// The optional purposes granted now.
        var granted: Set<String>
        /// The configuration's required purposes (`necessary` until it is known).
        var required: Set<String>
        var consentId: String?
        var decidedAt: Int64?
        var gcmMap: [String: String]
    }

    static let openingGapMs: Int64 = 30 * 60 * 1000
    static let textsBudget: Double = 1.5
    /// The vendor list and IAB's texts before the TCF layers show (the web holds its first layer 3 s at most).
    static let tcfBudget: Double = 3
    static let debugLaunchesBeforeWarning = 10

    let queue: DispatchQueue
    let env: CMPEnvironment
    let options: Options
    weak var host: CMPHost?
    /// The IAB TCF (§6): its keys, strings and layers.
    let tcf: CMPTCF
    let beacons: BeaconQueue

    private let lock = NSLock()
    private var snap: Snapshot

    // Queue-confined state.
    private var stored: StoredChoice?
    private var appConfig: AppConfig?
    private var configBody: Data?
    private var meta: ConfigMeta?
    private var fetching = false
    private var language: String?
    private var opening: Opening?
    private var backgroundAt: Int64?
    private var showing: SheetModel.Kind?
    private var shownAt: Int64 = 0
    private var counters: Counters
    private var reportingSDKs = false
    private var readyQueue: [(ScruterCMP.Choice) -> Void] = []
    private var observers: [Int: (ScruterCMP.Choice) -> Void] = [:]
    /// The choice the app's callbacks last saw (`whenReady` once, then `onChange`).
    private var delivered: ScruterCMP.Choice?
    private var pendingShow: AnyObject??
    var forceShow = false

    struct ConfigMeta {
        var etag: String?
        var fetchedAt: Int64
        var ttl: Int

        var json: JSONObject { ["etag": etag ?? "", "fetchedAt": fetchedAt, "ttl": ttl] }

        @_optimize(size) init(etag: String?, fetchedAt: Int64, ttl: Int) {
            self.etag = etag
            self.fetchedAt = fetchedAt
            self.ttl = ttl
        }

        @_optimize(size) init?(json j: JSONObject?) {
            guard let j = j, let at = j.int64("fetchedAt") else { return nil }
            self.init(etag: j.str("etag").flatMap { $0.isEmpty ? nil : $0 }, fetchedAt: at, ttl: j.int("ttl") ?? 300)
        }
    }

    struct Counters {
        /// `<app version>|<catalogue version>` reported (§3.14).
        var sdkReport: String?
        /// Launches of a debug build with a choice and no `showPreferences()` call (§2.5).
        var launches = 0
        var preferencesCalled = false

        var json: JSONObject { ["sdkReport": sdkReport ?? "", "launches": launches, "preferencesCalled": preferencesCalled] }

        @_optimize(size) init() {}

        @_optimize(size) init(json j: JSONObject?) {
            sdkReport = j?.str("sdkReport").flatMap { $0.isEmpty ? nil : $0 }
            launches = j?.int("launches") ?? 0
            preferencesCalled = j?.bool("preferencesCalled") ?? false
        }
    }

    @_optimize(size) private func saveCounters() { env.files.writeObject("state.json", counters.json) }

    struct Opening {
        /// `a` or `b` during an A/B test.
        var variant: String?
        var banner: BannerRef
        var ui: UiConfig
        var displayed = false
        var hitSent = false
    }

    @_optimize(size) init(env: CMPEnvironment, options: Options, queue: DispatchQueue) {
        self.env = env
        self.options = options
        self.queue = queue
        beacons = BeaconQueue(env: env)
        tcf = CMPTCF(env: env)
        counters = Counters()
        // The one storage read on the caller's thread (§3.1): `isGranted` answers from the next line.
        stored = env.choice.read().flatMap(StoredChoice.parse)
        snap = Snapshot(
            state: stored == nil ? .needsDecision : .ready, granted: Set(stored?.granted ?? []), required: ["necessary"],
            consentId: stored?.id, decidedAt: stored?.at, gcmMap: ConsentModeRules.defaultMap)
        beacons.onAcknowledged = { [weak self] key in self?.acknowledged(key) }
        tcf.listLoaded = { [weak self] in self?.evaluate() }
    }

    // MARK: Public API (any thread)

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snap
    }

    @_optimize(size) private func update(_ change: (inout Snapshot) -> Void) {
        lock.lock()
        change(&snap)
        let s = snap
        lock.unlock()
        if CMPBridge.active { CMPBridge.shared.changed(self, s, optional: appConfig?.usable?.0.optional.map { $0.key }) }
    }

    @_optimize(size) func isGranted(_ key: String) -> Bool {
        let s = snapshot
        return s.required.contains(key) || key == "necessary" || s.granted.contains(key)
    }

    // MARK: Lifecycle (queue)

    /// After `init`, on the queue: the cached configuration, the first evaluation, the opening, the network.
    @_optimize(size) func start() {
        env.files.prepare()
        if env.device.detectDebugBuild {
            env.device.isDebugBuild = CMPPlatform.isDebugBuild()
            env.log.warningsEnabled = env.device.isDebugBuild
        }
        counters = Counters(json: env.files.readObject("state.json"))
        beacons.load()
        configBody = env.files.read("config.json")
        appConfig = configBody.flatMap(AppConfig.init(data:))
        meta = ConfigMeta(json: env.files.readObject("config-meta.json"))
        if let c = appConfig?.usable?.0 { beacons.endpoint = URL(string: c.endpoint) }
        if appConfig != nil { tcf.configure(appConfig?.usable?.0) }
        if env.device.isDebugBuild { countDebugLaunch() }
        let config = appConfig?.usable
        env.log.log("start, cached configuration", config.map { "revision " + String($0.0.config_rev) } ?? "none")
        if let (_, app) = config, !app.ids.contains(env.device.bundleId.lowercased()) {
            env.log.warn("the bundle id " + env.device.bundleId + " is not one of the app's identifiers in Scruter: its beacons are dropped")
        }
        beginOpening()
        evaluate()
        resendPending()
        beacons.flush()
        fetchConfigIfStale()
        reportSDKsIfNeeded()
    }

    @_optimize(size) func didEnterBackground() {
        backgroundAt = env.now()
        // The opening's hit leaves now if the sheet never showed (as the web's `pagehide`).
        sendHit()
    }

    @_optimize(size) func willEnterForeground() {
        let now = env.now()
        if let b = backgroundAt, now - b >= CMPEngine.openingGapMs { beginOpening() }
        backgroundAt = nil
        evaluate()
        beacons.retryNow()
        fetchConfigIfStale()
    }

    @_optimize(size) func networkAvailable() {
        beacons.retryNow()
        if appConfig?.usable == nil || isStale { fetchConfig() }
    }

    // MARK: Configuration

    private var isStale: Bool {
        guard let m = meta else { return true }
        return env.now() - m.fetchedAt >= Int64(m.ttl) * 1000
    }

    @_optimize(size) private func fetchConfigIfStale() {
        if appConfig == nil || isStale { fetchConfig() }
    }

    @_optimize(size) private func fetchConfig() {
        guard !fetching else { return }
        fetching = true
        var c = URLComponents(url: options.base.appendingPathComponent("m/v1/cmp"), resolvingAgainstBaseURL: false)
        c?.queryItems = [
            URLQueryItem(name: "a", value: options.appId), URLQueryItem(name: "p", value: "ios"),
            URLQueryItem(name: "av", value: env.device.appVersion), URLQueryItem(name: "sv", value: env.device.sdkVersion),
        ]
        guard let url = c?.url else { return }
        var headers = ["Accept": "application/json"]
        if let e = meta?.etag, appConfig != nil { headers["If-None-Match"] = e }
        env.http.send(CMPRequest(method: "GET", url: url, headers: headers, body: nil)) { [weak self] r in
            self?.configAnswered(r)
        }
    }

    @_optimize(size) private func configAnswered(_ r: CMPResponse?) {
        fetching = false
        let now = env.now()
        guard let r = r else {
            env.log.log("configuration: no network")
            if appConfig == nil { evaluate() }
            return
        }
        if r.status == 304, appConfig != nil {
            meta?.fetchedAt = now
            if let m = meta { env.files.writeObject("config-meta.json", m.json) }
            return
        }
        guard r.status == 200, let next = AppConfig(data: r.body), next.v == 1 else {
            env.log.log("configuration refused, status", String(r.status))
            if appConfig == nil { evaluate() }
            return
        }
        let changed = r.body != configBody
        appConfig = next
        configBody = r.body
        meta = ConfigMeta(etag: r.headers["etag"], fetchedAt: now, ttl: max(60, min(next.ttl, 86400)))
        env.files.write("config.json", r.body)
        if let m = meta { env.files.writeObject("config-meta.json", m.json) }
        guard changed else { return }
        tcf.configure(next.usable?.0)
        if let (c, app) = next.usable {
            env.log.log("configuration revision", String(c.config_rev))
            beacons.endpoint = URL(string: c.endpoint)
            var urls = [String]()
            if let i = app.icon { urls.append(i) }
            if let l = c.ui.logo_url { urls.append(l) }
            for u in [c.ui] + (c.ab_test.map { [$0.b_ui] } ?? []) {
                if let h = u.hero { urls += h.poster.map { $0.url } }
            }
            host?.prefetch(urls)
            if opening == nil || opening?.banner.id != c.banner.id && opening?.banner.id != c.ab_test?.b.id { beginOpening() }
            beacons.flush()
        } else {
            env.log.log("the CMP is off for this app (on: 0)")
            opening = nil
        }
        evaluate()
        resendPending()
        reportSDKsIfNeeded()
    }

    // MARK: Evaluation (§3.1, §3.8)

    /// The state from the stored choice and the cached configuration; shows the sheet when it must.
    @_optimize(size) private func evaluate() {
        let now = env.now()
        let usable = appConfig?.usable
        var state: ScruterCMP.State
        var granted = Set<String>()
        var required: Set<String> = ["necessary"]
        var gcmMap = ConsentModeRules.defaultMap
        if let (c, _) = usable {
            required = Set(c.purposes.filter { $0.required }.map { $0.key })
            if let g = c.gcm { gcmMap = g.map }
            let optional = Set(c.optional.map { $0.key })
            let held = Set(stored?.granted ?? []).intersection(optional)
            switch Rules.reask(stored, config: c, now: now / 1000) {
            case nil:
                if tcf.mustAsk() {
                    state = .needsDecision
                    granted = held
                } else {
                    state = .ready
                    granted = held
                }
            case .noChoice?, .expired?:
                state = .needsDecision
                // An expired consent is no consent: vendors read none until the new decision.
                tcf.clearDecision()
            case .changed(let keys)?:
                // The purposes that did not change keep their answer until the new decision (§3.8).
                state = .needsDecision
                granted = held.subtracting(keys)
            }
        } else {
            // No configuration, or the CMP is off: every optional purpose denied (§3.1).
            state = .unavailable
        }
        let s = stored
        update {
            $0.state = state
            $0.granted = granted
            $0.required = required
            $0.consentId = s?.id
            $0.decidedAt = s?.at
            $0.gcmMap = gcmMap
        }
        env.log.log("state", state.rawValue)
        notify()
        if state == .unavailable {
            if showing != nil {
                showing = nil
                host?.dismiss()
            }
            return
        }
        sendHitIfSettled()
        if let anchor = pendingShow {
            pendingShow = nil
            present(.banner, anchor: anchor, force: false)
        } else if options.automatic && (state == .needsDecision || forceShow) {
            present(.banner, anchor: nil, force: forceShow)
        }
    }

    /// The app's callbacks: `whenReady` once a valid choice exists, `onChange` for every later change.
    @_optimize(size) private func notify() {
        let s = snapshot
        guard s.state != .unavailable || delivered != nil else { return }
        guard let id = s.consentId, let at = s.decidedAt else { return }
        let optional = appConfig?.usable.map { Set($0.0.optional.map { $0.key }) } ?? s.granted
        let choice = ScruterCMP.Choice(
            consentId: id, decidedAt: Date(timeIntervalSince1970: TimeInterval(at)), granted: s.granted,
            denied: optional.subtracting(s.granted))
        if s.state == .ready, !readyQueue.isEmpty {
            let callbacks = readyQueue
            readyQueue = []
            host?.deliver { for cb in callbacks { cb(choice) } }
        }
        if let d = delivered, d != choice {
            let obs = Array(observers.values)
            host?.deliver { for cb in obs { cb(choice) } }
        }
        if delivered != nil || s.state == .ready { delivered = choice }
    }

    @_optimize(size) func whenReady(_ cb: @escaping (ScruterCMP.Choice) -> Void) {
        let s = snapshot
        if s.state == .ready, let id = s.consentId, let at = s.decidedAt, appConfig?.usable != nil {
            let optional = appConfig?.usable.map { Set($0.0.optional.map { $0.key }) } ?? []
            let choice = ScruterCMP.Choice(
                consentId: id, decidedAt: Date(timeIntervalSince1970: TimeInterval(at)), granted: s.granted,
                denied: optional.subtracting(s.granted))
            if delivered == nil { delivered = choice }
            host?.deliver { cb(choice) }
        } else {
            readyQueue.append(cb)
        }
    }

    @_optimize(size) func addObserver(id: Int, _ cb: @escaping (ScruterCMP.Choice) -> Void) {
        observers[id] = cb
    }

    @_optimize(size) func removeObserver(_ id: Int) { observers[id] = nil }

    // MARK: Openings and hits (§3.10, M9)

    /// A cold start or a return after 30 minutes: a page view, with its own A/B draw (docs/CMP.md §7.3).
    @_optimize(size) private func beginOpening() {
        guard let (c, _) = appConfig?.usable else {
            opening = nil
            return
        }
        var o = Opening(variant: nil, banner: c.banner, ui: c.ui)
        if let ab = c.ab_test {
            let b = env.percent() < ab.split_b
            o.variant = b ? "b" : "a"
            if b {
                o.banner = ab.b
                o.ui = ab.b_ui
            }
        }
        opening = o
    }

    /// A ready choice settles the opening at once; a sheet to show settles it when it shows (or at the background).
    @_optimize(size) private func sendHitIfSettled() {
        if snapshot.state == .ready && !(options.automatic && forceShow) { sendHit() }
    }

    @_optimize(size) private func sendHit() {
        guard var o = opening, !o.hitSent, let (c, _) = appConfig?.usable else { return }
        o.hitSent = true
        opening = o
        var body: [String: Any] = [
            "s": c.site, "b": o.banner.id, "l": lang(for: o.ui), "d": o.displayed ? 1 : 0, "w": env.device.shortSide,
            "cv": env.device.sdkName + "/" + env.device.sdkVersion, "e": 0,
        ]
        if let ab = c.ab_test, let v = o.variant {
            body["t"] = ab.id
            body["a"] = v
        }
        addAppFields(&body)
        env.log.log("opening, sheet shown:", o.displayed ? "yes" : "no")
        beacons.add(path: "/cmp/hit", body: encode(body))
    }

    @_optimize(size) private func addAppFields(_ body: inout [String: Any]) {
        body["p"] = "ios"
        body["ap"] = env.device.bundleId
        body["av"] = env.device.appVersion
        if env.device.isDebugBuild { body["dbg"] = 1 }
    }

    @_optimize(size) private func encode(_ body: [String: Any]) -> Data { JSON.data(body) }

    // MARK: Language and texts

    @_optimize(size) func setLanguage(_ l: String?) { language = l }

    @_optimize(size) private func lang(for ui: UiConfig) -> String {
        Rules.pickLanguage(
            enabled: ui.languages, fallback: ui.default_language, preferred: (language.map { [$0] } ?? []) + env.device.languages,
            aliases: ui.aliases ?? [:])
    }

    @_optimize(size) private func packName(_ banner: Int, _ lang: String) -> String { "texts-\(banner)-\(lang).json" }

    /// The texts and hash of `lang` for a version: inlined, cached, or fetched once (1.5 s at most, then the inlined
    /// language, as the web does).
    private func texts(banner: Int, ui: UiConfig, lang: String, endpoint: String, site: String,
                       done: @escaping (_ lang: String, Texts, String) -> Void) {
        if let t = ui.texts[lang], let h = ui.text_hashes[lang] { return done(lang, t, h) }
        if let p = env.files.read(packName(banner, lang)).flatMap(LanguagePack.init(data:)) { return done(lang, p.texts, p.hash) }
        let fallback = ui.default_language
        guard let ft = ui.texts[fallback], let fh = ui.text_hashes[fallback],
            let url = URL(string: endpoint + "/cmp/\(site)/texts-\(banner)-\(lang).json")
        else { return }
        var finished = false
        let timer = env.scheduler.schedule(after: CMPEngine.textsBudget) {
            guard !finished else { return }
            finished = true
            done(fallback, ft, fh)
        }
        env.http.send(CMPRequest(method: "GET", url: url, headers: [:], body: nil)) { [weak self] r in
            guard let self = self else { return }
            var result: (String, Texts, String) = (fallback, ft, fh)
            if let r = r, r.status == 200, let p = LanguagePack(data: r.body) {
                self.env.files.write(self.packName(banner, lang), r.body)
                result = (lang, p.texts, p.hash)
            }
            guard !finished else { return }
            finished = true
            timer.cancel()
            done(result.0, result.1, result.2)
        }
    }

    // MARK: The sheet

    /// `showIfNeeded(from:)`: the sheet when a decision is needed (manual presentation, §3.2).
    @_optimize(size) func showIfNeeded(anchor: AnyObject?) {
        if appConfig?.usable == nil {
            pendingShow = .some(anchor)
            fetchConfigIfStale()
            return
        }
        let s = snapshot.state
        if s == .needsDecision || forceShow { present(.banner, anchor: anchor, force: forceShow) }
    }

    /// `showPreferences(from:)`: the app's settings entry (§2.5).
    @_optimize(size) func showPreferences(anchor: AnyObject?) {
        if !counters.preferencesCalled {
            counters.preferencesCalled = true
            saveCounters()
        }
        guard appConfig?.usable != nil else {
            env.log.warn("showPreferences: no configuration yet (offline first launch, or the CMP is off for this app)")
            return
        }
        present(.preferences, anchor: anchor, force: true)
    }

    @_optimize(size) private func present(_ kind: SheetModel.Kind, anchor: AnyObject?, force: Bool) {
        guard showing == nil, let (c, app) = appConfig?.usable else { return }
        if opening == nil { beginOpening() }
        guard let o = opening else { return }
        if kind == .banner && !force && snapshot.state != .needsDecision { return }
        showing = kind
        let l = lang(for: o.ui)
        texts(banner: o.banner.id, ui: o.ui, lang: l, endpoint: c.endpoint, site: c.site) { [weak self] lang, t, h in
            guard let self = self, self.showing == kind else { return }
            guard self.tcf.on else {
                return self.show(kind, self.model(kind: kind, config: c, app: app, opening: o, lang: lang, texts: t, hash: h, tcf: nil), o, anchor)
            }
            self.tcf.sheet(lang: lang, budget: CMPEngine.tcfBudget) { [weak self] list in
                guard let self = self, self.showing == kind else { return }
                let sheet = list.flatMap { self.tcfSheet(list: $0, config: c, opening: o, lang: lang, texts: t) }
                self.show(kind, self.model(kind: kind, config: c, app: app, opening: o, lang: lang, texts: t, hash: h, tcf: sheet), o, anchor)
            }
        }
    }

    @_optimize(size) private func show(_ kind: SheetModel.Kind, _ model: SheetModel, _ o: Opening, _ anchor: AnyObject?) {
        let delay = kind == .banner ? Double(max(0, min(o.ui.delay_s ?? 0, 10))) : 0
        let show = { [weak self] in
            guard let self = self, self.showing == kind else { return }
            self.env.log.log("sheet", kind == .banner ? "banner" : "preferences")
            self.host?.show(model, anchor: anchor)
        }
        if delay > 0 { env.scheduler.schedule(after: delay, show) } else { show() }
    }

    /// The TCF layers' data in the drawn language (nil: no selected vendor in the vendor list).
    private func tcfSheet(list: VendorList, config c: CMPConfig, opening o: Opening, lang: String, texts t: Texts) -> TcfSheet? {
        guard let s = tcf.settings else { return nil }
        var words = Words.of(lang)
        if lang.lowercased().hasPrefix("fr") { words = words.french() }
        let names = t.purposes.mapValues { $0.name }
        return TcfSheet(
            settings: s, list: list, purposes: c.purposes, names: names, words: words, lang: lang,
            stored: stored == nil ? nil : tcf.storedChoice(), renewMonths: c.renew_months)
    }

    private func model(kind: SheetModel.Kind, config c: CMPConfig, app: AppBlock, opening o: Opening, lang: String,
                       texts t: Texts, hash: String, tcf: TcfSheet?) -> SheetModel {
        let fr = lang.lowercased().hasPrefix("fr")
        var drawn = t
        var words = Words.of(lang)
        if fr {
            let f = Typography.frenchSpacing
            drawn.title = f(t.title)
            drawn.message = f(t.message)
            drawn.kicker = t.kicker.map(f)
            drawn.accept_all = f(t.accept_all)
            drawn.reject_all = f(t.reject_all)
            drawn.customize = f(t.customize)
            drawn.save = f(t.save)
            drawn.close = f(t.close)
            drawn.preferences_title = f(t.preferences_title)
            drawn.preferences_intro = f(t.preferences_intro)
            drawn.purposes = t.purposes.mapValues { PurposeTexts(name: f($0.name), description: f($0.description)) }
            words = words.french()
        }
        let providers = o.ui.providers ?? [:]
        @_optimize(size) func purpose(_ p: PurposeRef) -> SheetModel.Purpose {
            let pt = drawn.purposes[p.key]
            return SheetModel.Purpose(
                key: p.key, name: pt?.name ?? p.key, description: pt?.description ?? "", providers: providers[p.key] ?? [])
        }
        let s = snapshot
        let mode = o.ui.logo_mode ?? "custom"
        let logo: String? = mode == "none" ? nil : (o.ui.logo_url ?? (mode == "auto" ? app.icon : nil))
        let rtl = (o.ui.rtl ?? []).contains(lang) || ["ar", "he", "fa", "ur"].contains(String(lang.prefix(2)))
        return SheetModel(
            kind: kind, lang: lang, rtl: rtl, texts: drawn, hash: hash, words: words, theme: o.ui.theme, color: o.ui.color,
            twoButtons: o.ui.buttons == "two" && o.ui.close_link, closeLink: o.ui.close_link, branding: o.ui.branding,
            hero: o.ui.hero, noPanel: o.ui.no_panel == true, logoURL: logo, logoIsIcon: mode == "auto",
            policyURL: app.policy_url ?? t.policy_url, purposes: c.optional.map(purpose),
            required: c.purposes.filter { $0.required }.map(purpose), granted: s.granted,
            consentId: stored?.id, decidedAt: stored?.at, banner: o.banner.id, tcf: tcf)
    }

    /// The sheet is on screen: the opening's hit says so (`d = 1`).
    @_optimize(size) func sheetDidAppear(_ kind: SheetModel.Kind) {
        shownAt = env.now()
        guard kind == .banner, var o = opening else { return }
        o.displayed = true
        opening = o
        sendHit()
    }

    /// The sheet closed without a decision (the preferences' close button).
    @_optimize(size) func sheetDidClose() {
        showing = nil
    }

    // MARK: Decisions (§3.3)

    /// Records a decision: the stored value is written before this returns (M5, before the sheet closes); the proof
    /// leaves right after, pending until acknowledged.
    @_optimize(size) func decide(_ d: SheetDecision, model: SheetModel) {
        guard let (c, _) = appConfig?.usable else { return }
        let now = env.now()
        let before = snapshot
        var granted = [String]()
        var denied = [String]()
        for p in c.optional { if d.granted.contains(p.key) { granted.append(p.key) } else { denied.append(p.key) } }
        let hadGranted = before.consentId != nil ? before.granted : nil
        let action = Rules.action(explicit: d.action, granted: granted, denied: denied, before: hadGranted)
        let s = StoredChoice(
            id: stored?.id ?? StoredChoice.newConsentId(), at: now / 1000, rev: c.consent_rev, banner: model.banner,
            granted: granted, pending: .init(action: action, source: d.source))
        stored = s
        env.choice.write(s.serialized)
        tcf.decide(granted: Set(granted), choice: d.tcf, config: c, lang: model.lang)
        if counters.launches != 0 {
            counters.launches = 0
            saveCounters()
        }
        let ms = d.source == .banner && shownAt > 0 ? min(now - shownAt, 86_400_000) : 0
        showing = nil
        shownAt = 0
        env.log.log("decision", action.rawValue + " from " + d.source.rawValue + ", granted: " + granted.joined(separator: ","))
        update {
            $0.state = .ready
            $0.granted = Set(granted)
            $0.consentId = s.id
            $0.decidedAt = s.at
        }
        notify()
        if var o = opening, !o.hitSent, d.source == .banner {
            o.displayed = true
            opening = o
        }
        sendHit()
        prove(s, banner: model.banner, lang: model.lang, hash: model.hash, ms: Int(ms))
    }

    /// `POST /cmp/consent` for a stored decision.
    @_optimize(size) private func prove(_ s: StoredChoice, banner: Int, lang: String, hash: String, ms: Int) {
        guard let p = s.pending, let (c, _) = appConfig?.usable else { return }
        let optional = c.optional.map { $0.key }
        let g = s.granted.filter { optional.contains($0) }
        var body: [String: Any] = [
            "s": c.site, "i": s.id, "b": banner, "c": p.action.rawValue, "o": p.source.rawValue, "l": lang, "h": hash,
            "g": g, "n": optional.filter { !g.contains($0) }, "r": s.rev, "w": env.device.shortSide, "ms": ms,
            "cv": env.device.sdkName + "/" + env.device.sdkVersion,
        ]
        // During a test the banner version names the variant answered.
        if let ab = c.ab_test, banner == ab.b.id || banner == c.banner.id {
            body["t"] = ab.id
            body["a"] = banner == ab.b.id ? "b" : "a"
        }
        if let gcm = c.gcm { body["m"] = ConsentModeRules.grantedSignals(map: gcm.map, granted: Set(g)) }
        if let f = tcf.proofFields() {
            body["tc"] = f.tc
            body["gv"] = f.gv
        }
        addAppFields(&body)
        beacons.add(path: "/cmp/consent", body: encode(body), proves: s.id + "." + String(s.at))
    }

    /// The ingest has the proof: unless a newer decision replaced it, the pending flag goes.
    @_optimize(size) private func acknowledged(_ key: String) {
        guard var s = stored, s.id + "." + String(s.at) == key, s.pending != nil else { return }
        s.pending = nil
        stored = s
        env.choice.write(s.serialized)
    }

    /// A proof not acknowledged at an earlier launch (killed during the decision, offline beyond 48 hours) is sent
    /// again while its banner version is live, as the web does; else its flag goes.
    @_optimize(size) private func resendPending() {
        guard let s = stored, s.pending != nil, let (c, _) = appConfig?.usable else { return }
        let key = s.id + "." + String(s.at)
        guard !beacons.hasProof(of: key) else { return }
        let isB = c.ab_test.map { s.banner == $0.b.id } ?? false
        guard s.banner == c.banner.id || isB else { return acknowledged(key) }
        let ui = isB ? c.ab_test!.b_ui : c.ui
        let l = lang(for: ui)
        let pack = env.files.read(packName(s.banner, l)).flatMap(LanguagePack.init(data:))
        let (lang, hash) = ui.text_hashes[l].map { (l, $0) } ?? pack.map { (l, $0.hash) }
            ?? (ui.default_language, ui.text_hashes[ui.default_language] ?? "")
        guard !hash.isEmpty else { return }
        env.log.log("pending proof sent again")
        prove(s, banner: s.banner, lang: lang, hash: hash, ms: 0)
    }

    // MARK: Debug (§3.13, §2.5)

    /// Forgets the choice (debug builds): the sheet shows again.
    @_optimize(size) func debugReset() {
        guard env.device.isDebugBuild else {
            env.log.warn("debugReset() works in debug builds only: a release build withdraws through the preferences")
            return
        }
        stored = nil
        env.choice.write(nil)
        tcf.reset()
        tcf.configure(appConfig?.usable?.0)
        counters = Counters()
        env.files.remove("state.json")
        delivered = nil
        env.log.log("choice forgotten (debugReset)")
        evaluate()
    }

    @_optimize(size) private func countDebugLaunch() {
        guard stored != nil, !counters.preferencesCalled else { return }
        counters.launches += 1
        saveCounters()
        if counters.launches >= CMPEngine.debugLaunchesBeforeWarning {
            env.log.warn(
                "showPreferences() was never called in \(counters.launches) launches since the last decision: add an entry such as « Gérer mes cookies » to the app's settings that calls ScruterCMP.showPreferences(from:) (docs: CMP.md, Withdrawal)")
        }
    }

    // MARK: Detected SDKs (§3.14)

    @_optimize(size) private func reportSDKsIfNeeded() {
        guard !reportingSDKs, let (c, app) = appConfig?.usable else { return }
        let key = env.device.appVersion + "|" + String(app.sdk_catalogue)
        guard counters.sdkReport != key else { return }
        reportingSDKs = true
        let version = app.sdk_catalogue
        let file = "sdks-\(version).json"
        let check: (SDKCatalogue) -> Void = { [weak self] cat in
            guard let self = self else { return }
            let found = cat.sdks.filter { e in e.ios.contains { self.env.classExists($0) } }.map { $0.k }.sorted()
            let body: [String: Any] = ["a": c.site, "p": "ios", "av": self.env.device.appVersion, "c": version, "k": found]
            let url = self.options.base.appendingPathComponent("m/v1/cmp/sdks")
            self.env.log.log("detected SDKs:", found.joined(separator: ", "))
            self.env.http.send(
                CMPRequest(method: "POST", url: url, headers: ["Content-Type": "application/json"], body: self.encode(body))
            ) { [weak self] r in
                guard let self = self else { return }
                self.reportingSDKs = false
                if let r = r, (200..<300).contains(r.status) {
                    self.counters.sdkReport = key
                    self.self.saveCounters()
                }
            }
        }
        if let cat = env.files.read(file).flatMap(SDKCatalogue.init(data:)) { return check(cat) }
        let url = options.base.appendingPathComponent("m/v1/cmp/sdks/\(version).json")
        env.http.send(CMPRequest(method: "GET", url: url, headers: [:], body: nil)) { [weak self] r in
            guard let self = self else { return }
            guard let r = r, r.status == 200, let cat = SDKCatalogue(data: r.body) else {
                self.reportingSDKs = false
                return
            }
            self.env.files.write(file, r.body)
            check(cat)
        }
    }
}
