import Foundation
import XCTest

@testable import ScruterCMP

/// The kit `sdk/protocol/cmp/` (vectors, golden bodies, words), read from the repository.
enum Kit {
    static let sdk = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let cmp = sdk.appendingPathComponent("protocol/cmp")

    static func data(_ path: String) -> Data {
        guard let d = try? Data(contentsOf: cmp.appendingPathComponent(path)) else {
            fatalError("missing kit file " + path)
        }
        return d
    }

    static func json(_ path: String) -> Any { try! JSONSerialization.jsonObject(with: data(path)) }

    /// Where the bodies the SDK sent are written, for `ios/scripts/cmp-conformance.sh` (JSON Schema validation).
    static let bodiesDir: URL = {
        let env = ProcessInfo.processInfo.environment["SCRUTER_CMP_BODIES"]
        let u = env.map { URL(fileURLWithPath: $0) } ?? sdk.appendingPathComponent(".build/cmp-bodies")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func record(_ schema: String, _ name: String, _ body: Data) {
        try? body.write(to: bodiesDir.appendingPathComponent(schema + "--" + name + ".json"))
    }
}

/// Virtual time: blocks run when the test advances the clock.
final class ManualScheduler: CMPScheduler {
    var now: Int64 = 1_790_000_000_000
    private var tasks: [(at: Int64, seq: Int, s: CMPScheduled, block: () -> Void)] = []
    private var seq = 0

    @discardableResult
    func schedule(after seconds: Double, _ block: @escaping () -> Void) -> CMPScheduled {
        let s = CMPScheduled()
        seq += 1
        tasks.append((now + Int64(max(0, seconds) * 1000), seq, s, block))
        return s
    }

    func advance(_ ms: Int64) {
        let end = now + ms
        while let next = tasks.filter({ $0.at <= end && !$0.s.cancelled }).min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) {
            tasks.removeAll { $0.seq == next.seq }
            now = max(now, next.at)
            next.block()
        }
        tasks.removeAll { $0.s.cancelled }
        now = end
    }
}

/// A fake ingest: the golden configuration, `202` for the beacons; records every request.
final class FakeIngest: CMPHTTP {
    var requests: [CMPRequest] = []
    var config: Data = Kit.data("bodies/config.json")
    var configStatus = 200
    var beaconStatus = 202
    var offline = false
    var hold = false
    /// Requests whose path contains one of these never get an answer until `release`.
    var holdPaths: [String] = []
    var held: [(CMPRequest, (CMPResponse?) -> Void)] = []
    var extra: (CMPRequest) -> CMPResponse? = { _ in nil }

    func send(_ request: CMPRequest, completion: @escaping (CMPResponse?) -> Void) {
        requests.append(request)
        if hold || holdPaths.contains(where: { request.url.path.contains($0) }) {
            held.append((request, completion))
            return
        }
        completion(answer(request))
    }

    /// A strong ETag of the configuration served (`"a-<20 hex>"` in production).
    var etag: String { "\"a-" + String(UInt64(bitPattern: Int64(config.hashValue)), radix: 16) + "\"" }

    func answer(_ request: CMPRequest) -> CMPResponse? {
        if offline { return nil }
        if let r = extra(request) { return r }
        let path = request.url.path
        if path.hasSuffix("/m/v1/cmp") {
            if request.headers["If-None-Match"] == etag && configStatus == 200 {
                return CMPResponse(status: 304, headers: [:], body: Data())
            }
            return CMPResponse(status: configStatus, headers: ["etag": etag], body: config)
        }
        // The IAB TCF: the kit's vendor subset and translations (sdk/protocol/cmp/tcf).
        if path.hasPrefix("/cmp/ATMONA02/vendors-") {
            return CMPResponse(status: 200, headers: [:], body: Kit.data("tcf/vendors-186.json"))
        }
        if path.hasPrefix("/cmp/tcf/186/"), let lang = path.split(separator: "/").last?.split(separator: ".").first,
            let d = try? Data(contentsOf: Kit.cmp.appendingPathComponent("tcf/186-\(lang).json")) {
            return CMPResponse(status: 200, headers: [:], body: d)
        }
        if path.hasSuffix("/m/v1/cmp/sdks/1.json") {
            let cat = #"{"v":1,"sdks":[{"k":"firebase_analytics","ios":["FIRAnalytics"]},{"k":"google_mobile_ads","ios":["GADMobileAds"]},{"k":"appsflyer","ios":["AppsFlyerLib"]},{"k":"adjust","ios":["Adjust"]}]}"#
            return CMPResponse(status: 200, headers: [:], body: Data(cat.utf8))
        }
        return CMPResponse(status: beaconStatus, headers: [:], body: Data("{}".utf8))
    }

    func release(_ response: CMPResponse? = nil) {
        let h = held
        held = []
        for (r, c) in h { c(response ?? answer(r)) }
    }

    func bodies(_ path: String) -> [[String: Any]] {
        requests.filter { $0.url.path.hasSuffix(path) && $0.method == "POST" }.compactMap {
            $0.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    func count(_ suffix: String) -> Int { requests.filter { $0.url.path.hasSuffix(suffix) }.count }
}

final class MemoryChoice: CMPChoiceStore {
    var value: String?
    var writes = 0
    var reads = 0
    func read() -> String? {
        reads += 1
        return value
    }
    func write(_ v: String?) {
        value = v
        writes += 1
    }
}

/// `UserDefaults` in memory: the IAB keys, the module's suite.
final class MemoryKeys: CMPKeyStore {
    var values: [String: Any] = [:]
    var writes: [[String: Any?]] = []
    func read(_ key: String) -> Any? { values[key] }
    func write(_ v: [String: Any?]) {
        writes.append(v)
        for (k, x) in v { values[k] = x }
    }
    /// The keys whose name starts with `IABTCF_`.
    var iab: [String: Any] { values.filter { $0.key.hasPrefix("IABTCF_") } }
}

/// Records what the engine asks of the screen.
final class RecordingHost: CMPHost {
    var shown: [SheetModel] = []
    var dismissed = 0
    var prefetched: [String] = []
    func show(_ model: SheetModel, anchor: AnyObject?) { shown.append(model) }
    func dismiss() { dismissed += 1 }
    func deliver(_ block: @escaping () -> Void) { block() }
    func prefetch(_ urls: [String]) { prefetched += urls }
}

/// An engine on fakes, driven synchronously (its queue is never used: every call runs on the test's thread).
final class Harness {
    let scheduler = ManualScheduler()
    let ingest = FakeIngest()
    let choice = MemoryChoice()
    let iab = MemoryKeys()
    let kept = MemoryKeys()
    let host = RecordingHost()
    let log = CMPLog()
    let dir: URL
    var device = CMPDevice(
        bundleId: "fr.ateliermona.app", appVersion: "2.3.0", shortSide: 393, languages: ["fr-FR", "en-GB"],
        isDebugBuild: false, sdkName: "ios", sdkVersion: "1.1.0")
    var classes: Set<String> = ["FIRAnalytics", "GADMobileAds"]
    var draw = 50
    var automatic = true
    private(set) var engine: CMPEngine!
    var logs: [String] = []

    /// The first process of a test owns the storage and deletes it.
    private let owner: Bool

    init(dir: URL? = nil) {
        owner = dir == nil
        self.dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("cmp-" + UUID().uuidString)
    }

    @discardableResult
    func start() -> CMPEngine {
        log.enabled = true
        log.sink = { [weak self] in self?.logs.append($0) }
        let env = CMPEnvironment(
            now: { [scheduler] in scheduler.now }, scheduler: scheduler, http: ingest, choice: choice, iab: iab, kept: kept,
            files: CMPFiles(directory: dir), log: log, device: device, classExists: { [classes] in classes.contains($0) },
            percent: { [weak self] in self?.draw ?? 50 })
        engine = CMPEngine(
            env: env, options: .init(appId: "ATMONA02", base: URL(string: "https://cdn.scruter.net")!, automatic: automatic),
            queue: DispatchQueue(label: "test"))
        engine.host = host
        engine.start()
        return engine
    }

    /// A new process on the same storage (the app killed and launched again).
    func relaunch() -> Harness {
        let h = Harness(dir: dir)
        h.choice.value = choice.value
        h.iab.values = iab.values
        h.kept.values = kept.values
        h.scheduler.now = scheduler.now
        h.ingest.config = ingest.config
        h.device = device
        h.classes = classes
        h.automatic = automatic
        return h
    }

    func decide(_ action: CMPAction?, granted: Set<String>, source: CMPSource = .banner) {
        let model = host.shown.last!
        engine.sheetDidAppear(model.kind)
        engine.decide(SheetDecision(action: action, granted: granted, source: source), model: model)
    }

    deinit { if owner { try? FileManager.default.removeItem(at: dir) } }
}

/// The golden configuration with `edit` applied.
func config(_ edit: (inout [String: Any]) -> Void) -> Data {
    var c = Kit.json("bodies/config.json") as! [String: Any]
    edit(&c)
    return try! JSONSerialization.data(withJSONObject: c)
}

func editConfig(_ c: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
    var inner = c["config"] as! [String: Any]
    edit(&inner)
    c["config"] = inner
}
