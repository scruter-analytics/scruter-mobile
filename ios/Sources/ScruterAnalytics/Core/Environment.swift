import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The SDK's version, sent as `sdk` (`ios/1.0.0`) and in the configuration request (`sv`).
public let scruterSDKVersion = "1.1.0"

/// Something scheduled that can be cancelled.
final class Scheduled {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

/// Runs blocks later on the engine's queue. The engine never blocks a thread and never runs a timer in the background
/// (docs/MOBILE.md §3.18): every delay goes through here.
protocol Scheduler: AnyObject {
    @discardableResult
    func schedule(after seconds: Double, _ block: @escaping () -> Void) -> Scheduled
}

/// The real scheduler: `asyncAfter` on the engine's serial queue.
final class QueueScheduler: Scheduler {
    let queue: DispatchQueue
    init(queue: DispatchQueue) { self.queue = queue }

    @discardableResult
    func schedule(after seconds: Double, _ block: @escaping () -> Void) -> Scheduled {
        let s = Scheduled()
        queue.asyncAfter(deadline: .now() + max(0, seconds)) {
            if !s.cancelled { block() }
        }
        return s
    }
}

struct HTTPRequest {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?
}

struct HTTPResponse {
    var status: Int
    /// Header names lower-cased.
    var headers: [String: String]
    var body: Data
}

/// The network. `nil` response = a network error (no answer).
protocol HTTPClient: AnyObject {
    func send(_ request: HTTPRequest, completion: @escaping (HTTPResponse?) -> Void)
}

/// `URLSession`, ephemeral: no cookie, no cache, no credential storage. Completions hop to the engine's queue.
final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 120
        #if canImport(Darwin)
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 2
        #endif
        session = URLSession(configuration: c)
    }

    func send(_ request: HTTPRequest, completion: @escaping (HTTPResponse?) -> Void) {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = request.body
        let queue = self.queue
        session.dataTask(with: r) { data, response, _ in
            let result: HTTPResponse? = (response as? HTTPURLResponse).map { h in
                var headers = [String: String]()
                for (k, v) in h.allHeaderFields {
                    if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
                }
                return HTTPResponse(status: h.statusCode, headers: headers, body: data ?? Data())
            }
            queue.async { completion(result) }
        }.resume()
    }
}

/// The SDK's private files: `Library/Application Support/Scruter/` on iOS (excluded from backups), a directory of the
/// test's choosing elsewhere. Every write happens on the engine's queue, never on the main thread.
final class FileStore {
    let directory: URL
    private let fm = FileManager.default

    init(directory: URL) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #if canImport(Darwin)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        #endif
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func read(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }

    func write(_ name: String, _ data: Data) {
        #if canImport(Darwin)
        try? data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url(name), options: [.atomic])
        #endif
    }

    func append(_ name: String, _ data: Data) {
        let u = url(name)
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            write(name, data)
        }
    }

    func size(_ name: String) -> Int {
        (try? fm.attributesOfItem(atPath: url(name).path)[.size] as? Int) ?? 0
    }

    func remove(_ name: String) { try? fm.removeItem(at: url(name)) }

    func removeAll() {
        if let names = try? fm.contentsOfDirectory(atPath: directory.path) {
            for n in names { try? fm.removeItem(at: url(n)) }
        }
    }
}

/// Where a team phone's device token lives: the Keychain on iOS (this device only, after first unlock), a file in
/// tests.
protocol SecretStore: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
}

final class FileSecretStore: SecretStore {
    private let store: FileStore
    init(store: FileStore) { self.store = store }
    func get(_ key: String) -> String? { store.read("secret-\(key)").map { String(decoding: $0, as: UTF8.self) } }
    func set(_ key: String, _ value: String?) {
        if let v = value { store.write("secret-\(key)", Text.utf8(v)) } else { store.remove("secret-\(key)") }
    }
}

/// Debug logging (docs/MOBILE.md §3.17): off unless `debug: true`; property values only in debug builds.
final class Logger {
    var enabled = false
    var sink: (String) -> Void = { print("[Scruter] \($0)") }

    /// Parts joined with spaces. No autoclosure and no interpolation at the call sites: each costs hundreds of bytes.
    func log(_ a: StaticString, _ b: String = "", _ c: String = "") {
        guard enabled else { return }
        var m = a.description
        if !b.isEmpty { m += " " + b }
        if !c.isEmpty { m += " " + c }
        sink(m)
    }
}

/// What the SDK knows about the app and the phone model (docs/MOBILE.md §2.2): shared by millions, never a device.
struct DeviceInfo {
    var platform = "ios"
    var bundleId = ""
    var appVersion = "0"
    var appBuild = ""
    var os = ""
    var model = ""
    var form = "phone"
    var language = ""
    /// `release`, `testflight`, `test` or `debug`.
    var buildKind = "release"
    /// `app_store`, `testflight` or `other`: the install source class (docs/MOBILE.md §3.13).
    var installSource = "other"
    /// `NSAdvertisingAttributionReportEndpoint` of the Info.plist: who receives Apple's postback copies (§3.13).
    var copyEndpoint: String?
    /// A development-signed app or the simulator: the only builds that may use a debug key (§3.12).
    var isDebugBuild = false
    /// The SDK flavour sent as `sdk`: `ios`, or `react_native` / `flutter` when a cross-platform SDK embeds this one.
    var sdkName = "ios"
    var sdkVersion = scruterSDKVersion
    /// Creation of the app's own data container: tells a fresh install from an update that adds the SDK (§2.1).
    var containerCreatedMs: Int64?
}

/// Everything the engine reaches outside itself. Tests build one with fakes.
final class Environment {
    var now: () -> Int64
    let scheduler: Scheduler
    let http: HTTPClient
    let store: FileStore
    let secrets: SecretStore
    let log: Logger
    var device: DeviceInfo
    /// Lower-case hex gzip of a body (docs/MOBILE.md §3.15).
    var gzip: (Data) -> Data
    /// Asks the person holding the phone before a link makes it a team phone (docs/MOBILE.md §3.12). Nothing to ask with:
    /// no.
    var confirmTeamPhone: (@escaping (Bool) -> Void) -> Void = { $0(false) }

    init(
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        scheduler: Scheduler,
        http: HTTPClient,
        store: FileStore,
        secrets: SecretStore,
        log: Logger = Logger(),
        device: DeviceInfo,
        gzip: @escaping (Data) -> Data = Gzip.compress
    ) {
        self.now = now
        self.scheduler = scheduler
        self.http = http
        self.store = store
        self.secrets = secrets
        self.log = log
        self.device = device
        self.gzip = gzip
    }
}
