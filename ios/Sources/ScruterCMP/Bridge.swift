import Foundation

/// The entry points of Scruter's React Native and Flutter wrappers (not for apps: `@_spi`). The wrappers keep no state
/// of their own: the choice, the proofs and the queue stay in this module. They read one snapshot and hear its changes,
/// normalised here so that both toolkits behave alike on both platforms (docs/CMP-MOBILE.md §3.16).
extension ScruterCMP {
    /// Starts the module for a wrapper, once per process: `sdk` and `version` name the wrapper in `cv`
    /// (`react_native/1.1.0`). A second call (a JavaScript reload, a Flutter hot restart) starts nothing and returns
    /// `false`. `forceShow` and `debug` are set before the start, as an app sets them.
    @_spi(ScruterBridge)
    @discardableResult
    @_optimize(size) public static func _bridgeStart(
        appId: String, manual: Bool, endpoint: String?, sdk: String, version: String, forceShow: Bool, debug: Bool
    ) -> Bool {
        if CMPRuntime.shared.engine != nil { return false }
        CMPBridge.active = true
        _setBridge(sdk: sdk, version: version)
        if debug { ScruterCMP.debug = true }
        if forceShow { ScruterCMP.forceShow = true }
        start(appId: appId, presentation: manual ? .manual : .automatic, endpoint: endpoint.flatMap(URL.init(string:)))
        return true
    }

    /// Whether the module runs (a wrapper's reload finds it started).
    @_spi(ScruterBridge)
    public static var _bridgeStarted: Bool { CMPRuntime.shared.engine != nil }

    /// The module as the wrappers read it: `state` (`ready`, `needsDecision`, `unavailable`), `consentId`, `choice`
    /// (`consentId`, `decidedAt` in milliseconds, `granted`, `denied`; absent without a valid choice), `granted` (what
    /// `isGranted` answers now, the required purposes included) and `signals` (Consent Mode, `granted` or `denied`).
    @_spi(ScruterBridge)
    @_optimize(size) public static func _bridgeSnapshot() -> [String: Any] {
        CMPBridge.shared.current()
    }

    /// The running wrapper's listener, replacing the previous one (a reload replaces it, never adds one). Called on the
    /// main thread with each new snapshot, and `true` when it carries a new valid choice: a decision, the preferences,
    /// a withdrawal, a re-ask answered.
    @_spi(ScruterBridge)
    @_optimize(size) public static func _bridgeListen(_ listener: (([String: Any], Bool) -> Void)?) {
        CMPBridge.shared.setListener(listener)
    }
}

/// What the wrappers see of the engine. The engine tells it of every change of its snapshot, on its queue, only once a
/// wrapper started the module (`active`): a native app pays nothing for it.
final class CMPBridge {
    static let shared = CMPBridge()
    static var active = false

    private let lock = NSLock()
    private var latest: [String: Any]?
    private var listener: (([String: Any], Bool) -> Void)?
    private var choiceKey: String?
    /// The banner's optional purposes, as last known: a choice's refused ones.
    private var optional: [String] = []

    @_optimize(size) func setListener(_ l: (([String: Any], Bool) -> Void)?) {
        lock.lock()
        listener = l
        lock.unlock()
    }

    @_optimize(size) func current() -> [String: Any] {
        lock.lock()
        if let l = latest {
            lock.unlock()
            return l
        }
        let known = optional
        lock.unlock()
        guard let e = CMPRuntime.shared.engine else { return CMPBridge.stored(optional: known) }
        return CMPBridge.snapshot(e.snapshot, optional: known)
    }

    /// Before the engine exists: the stored choice, read as the engine's first line reads it. A wrapper's `start`
    /// reaches the main thread a moment after its runtime asked for it; `isGranted` answers from the stored choice
    /// meanwhile, as it does on the line after a native `start`.
    @_optimize(size) static func stored(optional: [String]) -> [String: Any] {
        guard let s = CMPDefaultsChoiceStore().read().flatMap(StoredChoice.parse) else {
            return snapshot(nil, optional: optional)
        }
        return snapshot(
            CMPEngine.Snapshot(
                state: .ready, granted: Set(s.granted), required: ["necessary"], consentId: s.id, decidedAt: s.at,
                gcmMap: ConsentModeRules.defaultMap),
            optional: optional)
    }

    /// On the engine's queue, after each change of its snapshot. `optional`: the configuration's optional purposes,
    /// nil while none is usable.
    @_optimize(size) func changed(_ engine: CMPEngine, _ s: CMPEngine.Snapshot, optional now: [String]?) {
        lock.lock()
        if let now = now { optional = now }
        let snap = CMPBridge.snapshot(s, optional: optional)
        var key: String?
        if let c = snap["choice"] as? [String: Any] {
            key = "\(c["consentId"] ?? "")|\(c["decidedAt"] ?? 0)|\((c["granted"] as? [String] ?? []).joined(separator: ","))"
        }
        let fresh = key != nil && key != choiceKey
        choiceKey = key
        let same = latest.map { NSDictionary(dictionary: $0).isEqual(to: snap) } ?? false
        latest = snap
        let l = listener
        lock.unlock()
        guard let listener = l, fresh || !same else { return }
        engine.host?.deliver { listener(snap, fresh) }
    }

    @_optimize(size) static func snapshot(_ s: CMPEngine.Snapshot?, optional: [String]) -> [String: Any] {
        guard let s = s else {
            return ["state": ScruterCMP.State.unavailable.rawValue, "granted": ["necessary"], "signals": signals(nil, map: nil)]
        }
        let granted = s.granted.union(s.required).union(["necessary"]).sorted()
        var out: [String: Any] = [
            "state": s.state.rawValue, "granted": granted,
            "signals": signals(s.consentId == nil ? nil : s.granted, map: s.gcmMap),
        ]
        if let id = s.consentId { out["consentId"] = id }
        if s.state == .ready, let id = s.consentId, let at = s.decidedAt {
            out["choice"] = [
                "consentId": id, "decidedAt": at * 1000, "granted": granted,
                "denied": optional.filter { !s.granted.contains($0) && !s.required.contains($0) }.sorted(),
            ] as [String: Any]
        }
        return out
    }

    @_optimize(size) private static func signals(_ granted: Set<String>?, map: [String: String]?) -> [String: String] {
        var out = [String: String]()
        for (k, v) in ConsentModeRules.signals(map: map ?? ConsentModeRules.defaultMap, granted: granted) {
            out[k] = v ? "granted" : "denied"
        }
        return out
    }

    /// Tests only.
    @_optimize(size) func reset() {
        lock.lock()
        latest = nil
        listener = nil
        choiceKey = nil
        optional = []
        lock.unlock()
    }
}
