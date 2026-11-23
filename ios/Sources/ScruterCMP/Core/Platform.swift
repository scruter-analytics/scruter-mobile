import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Something scheduled that can be cancelled.
final class CMPScheduled {
    private(set) var cancelled = false
    @_optimize(size) func cancel() { cancelled = true }
}

/// Runs blocks later on the engine's queue (no timer runs in the background).
protocol CMPScheduler: AnyObject {
    @discardableResult
    func schedule(after seconds: Double, _ block: @escaping () -> Void) -> CMPScheduled
}

final class CMPQueueScheduler: CMPScheduler {
    let queue: DispatchQueue
    @_optimize(size) init(queue: DispatchQueue) { self.queue = queue }

    @discardableResult
    @_optimize(size) func schedule(after seconds: Double, _ block: @escaping () -> Void) -> CMPScheduled {
        let s = CMPScheduled()
        queue.asyncAfter(deadline: .now() + max(0, seconds)) {
            if !s.cancelled { block() }
        }
        return s
    }
}

struct CMPRequest {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
}

struct CMPResponse {
    var status: Int
    /// Header names lower-cased.
    var headers: [String: String]
    var body: Data
}

/// The network. A `nil` response is a network error.
protocol CMPHTTP: AnyObject {
    func send(_ request: CMPRequest, completion: @escaping (CMPResponse?) -> Void)
}

/// An ephemeral `URLSession`: no cookie, no cache, no credential. Completions hop to the engine's queue.
final class CMPURLSession: CMPHTTP {
    private let session: URLSession
    private let queue: DispatchQueue

    @_optimize(size) init(queue: DispatchQueue) {
        self.queue = queue
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        #if canImport(Darwin)
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 2
        #endif
        session = URLSession(configuration: c)
    }

    @_optimize(size) func send(_ request: CMPRequest, completion: @escaping (CMPResponse?) -> Void) {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = request.body
        let queue = self.queue
        session.dataTask(with: r) { data, response, _ in
            let result: CMPResponse? = (response as? HTTPURLResponse).map { h in
                var headers = [String: String]()
                for (k, v) in h.allHeaderFields {
                    if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
                }
                return CMPResponse(status: h.statusCode, headers: headers, body: data ?? Data())
            }
            queue.async { completion(result) }
        }.resume()
    }
}

/// Where the stored choice lives (M5): `UserDefaults(suiteName: "net.scruter.cmp")`, key `choice`.
protocol CMPChoiceStore: AnyObject {
    func read() -> String?
    func write(_ value: String?)
}

final class CMPDefaultsChoiceStore: CMPChoiceStore {
    static let suite = "net.scruter.cmp"
    static let key = "choice"
    private let defaults: UserDefaults?

    @_optimize(size) init() { defaults = UserDefaults(suiteName: CMPDefaultsChoiceStore.suite) }

    @_optimize(size) func read() -> String? { defaults?.string(forKey: CMPDefaultsChoiceStore.key) }

    @_optimize(size) func write(_ value: String?) {
        if let v = value { defaults?.set(v, forKey: CMPDefaultsChoiceStore.key) } else {
            defaults?.removeObject(forKey: CMPDefaultsChoiceStore.key)
        }
    }
}

/// Values in `UserDefaults`: the IAB keys in `UserDefaults.standard`, where ad SDKs read them (docs/CMP-MOBILE.md §6),
/// and the stored TC string beside the choice (`net.scruter.cmp`, key `tcf`, as the web's `scruter_tcf`).
protocol CMPKeyStore: AnyObject {
    func read(_ key: String) -> Any?
    /// Sets each value; `nil` removes the key.
    func write(_ values: [String: Any?])
}

final class CMPDefaultsKeyStore: CMPKeyStore {
    private let defaults: UserDefaults?

    @_optimize(size) init(_ defaults: UserDefaults?) { self.defaults = defaults }

    @_optimize(size) func read(_ key: String) -> Any? { defaults?.object(forKey: key) }

    @_optimize(size) func write(_ values: [String: Any?]) {
        for (k, v) in values {
            if let v = v { defaults?.set(v, forKey: k) } else { defaults?.removeObject(forKey: k) }
        }
    }
}

/// The module's files: the cached configuration and texts, the beacon queue, a few counters. `Library/Application
/// Support/ScruterCMP/` on iOS, excluded from backups; written on the engine's queue only.
final class CMPFiles {
    let directory: URL
    private let fm = FileManager.default

    @_optimize(size) init(directory: URL) {
        self.directory = directory
    }

    /// Creates the directory (on the engine's queue).
    @_optimize(size) func prepare() {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        #endif
    }

    @_optimize(size) static func standard() -> CMPFiles {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return CMPFiles(directory: base.appendingPathComponent("ScruterCMP", isDirectory: true))
    }

    @_optimize(size) func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    @_optimize(size) func read(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }

    @_optimize(size) func write(_ name: String, _ data: Data) {
        #if canImport(Darwin)
        try? data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url(name), options: [.atomic])
        #endif
    }

    @_optimize(size) func remove(_ name: String) { try? fm.removeItem(at: url(name)) }

    @_optimize(size) func readObject(_ name: String) -> JSONObject? { JSON.object(read(name)) }

    @_optimize(size) func writeObject(_ name: String, _ value: Any) { write(name, JSON.data(value)) }
}

/// The debug log (§3.13): off unless `ScruterCMP.debug`. Never a consent id, never a personal datum.
final class CMPLog {
    var enabled = false
    var sink: (String) -> Void = { print("[ScruterCMP] \($0)") }

    @_optimize(size) func log(_ a: StaticString, _ b: String = "") {
        guard enabled else { return }
        sink(b.isEmpty ? a.description : a.description + " " + b)
    }

    /// Warnings show in debug builds even without `debug` (a misconfiguration the developer must see).
    var warningsEnabled = false

    @_optimize(size) func warn(_ message: String) {
        guard enabled || warningsEnabled else { return }
        sink("warning: " + message)
    }
}

/// What the beacons say about the app (§4.2): never a device identifier.
struct CMPDevice: Equatable {
    /// `Bundle.main.bundleIdentifier`: the beacons' `ap`.
    var bundleId = ""
    /// `CFBundleShortVersionString`: `av`.
    var appVersion = "0"
    /// The shorter side of the screen in points: `w`.
    var shortSide = 0
    /// The device's preferred languages, in order.
    var languages: [String] = []
    /// A development-signed app or the simulator: `dbg = 1` (§3.13). Read on the engine's queue at start (the
    /// provisioning profile is a file): `detectDebugBuild`.
    var isDebugBuild = false
    var detectDebugBuild = false
    /// `ios`, or `react_native` / `flutter` when a wrapper embeds this module: `cv`.
    var sdkName = "ios"
    var sdkVersion = scruterCMPVersion
}

/// Everything the engine reaches outside itself; tests build one with fakes.
final class CMPEnvironment {
    var now: () -> Int64
    let scheduler: CMPScheduler
    let http: CMPHTTP
    let choice: CMPChoiceStore
    /// `UserDefaults.standard`: the IAB TCF keys.
    let iab: CMPKeyStore
    /// The module's suite: the stored TC string.
    let kept: CMPKeyStore
    let files: CMPFiles
    let log: CMPLog
    var device: CMPDevice
    /// Whether a class of the app's binary exists (`NSClassFromString`, never instantiated).
    var classExists: (String) -> Bool
    /// A random number in 0..<100 (the A/B variant's draw).
    var percent: () -> Int

    init(
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        scheduler: CMPScheduler, http: CMPHTTP, choice: CMPChoiceStore,
        iab: CMPKeyStore = CMPDefaultsKeyStore(.standard),
        kept: CMPKeyStore = CMPDefaultsKeyStore(UserDefaults(suiteName: CMPDefaultsChoiceStore.suite)),
        files: CMPFiles, log: CMPLog = CMPLog(),
        device: CMPDevice, classExists: @escaping (String) -> Bool = { _ in false },
        percent: @escaping () -> Int = { Int.random(in: 0..<100) }
    ) {
        self.now = now
        self.scheduler = scheduler
        self.http = http
        self.choice = choice
        self.iab = iab
        self.kept = kept
        self.files = files
        self.log = log
        self.device = device
        self.classExists = classExists
        self.percent = percent
    }
}
