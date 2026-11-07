import Foundation
import XCTest

@_spi(ScruterBridge) @testable import ScruterAnalytics

#if canImport(Compression)
import Compression
#endif

/// Virtual time: blocks run when the test advances the clock.
final class ManualScheduler: Scheduler {
    var now: Int64 = 1_793_900_000_000
    private var tasks: [(at: Int64, seq: Int, s: Scheduled, block: () -> Void)] = []
    private var seq = 0

    @discardableResult
    func schedule(after seconds: Double, _ block: @escaping () -> Void) -> Scheduled {
        let s = Scheduled()
        seq += 1
        tasks.append((now + Int64(max(0, seconds) * 1000), seq, s, block))
        return s
    }

    /// Advances the clock by `ms`, running what falls due in order.
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

    var pending: Int { tasks.filter { !$0.s.cancelled }.count }
}

/// A fake network: records requests and answers with `respond` (synchronously, or kept for later with `hold`).
final class FakeHTTP: HTTPClient {
    var requests: [HTTPRequest] = []
    var respond: (HTTPRequest) -> HTTPResponse? = { req in
        if req.url.path.hasSuffix("/m/v1/config") {
            return HTTPResponse(status: 200, headers: [:], body: Data(#"{"v":1,"on":1,"e":"etag1","tz":"Europe/Paris","aa":0,"cr":1,"xs":["Debug*"],"tp":1,"ttl":3600}"#.utf8))
        }
        return HTTPResponse(status: 202, headers: [:], body: Data("{}".utf8))
    }
    var hold = false
    var held: [(HTTPRequest, (HTTPResponse?) -> Void)] = []

    func send(_ request: HTTPRequest, completion: @escaping (HTTPResponse?) -> Void) {
        requests.append(request)
        if hold {
            held.append((request, completion))
        } else {
            completion(respond(request))
        }
    }

    func release(_ response: HTTPResponse?) {
        let h = held
        held = []
        for (_, c) in h { c(response) }
    }

    var batches: [JSON] {
        requests.filter { $0.url.path.hasSuffix("/m/v1/batch") }.compactMap { req in
            req.body.flatMap { Gunzip.body($0, gzip: req.headers["Content-Encoding"] == "gzip") }.flatMap(JSON.parse)
        }
    }

    var configRequests: [HTTPRequest] { requests.filter { $0.url.path.hasSuffix("/m/v1/config") } }
}

enum Gunzip {
    static func body(_ data: Data, gzip: Bool) -> Data? {
        guard gzip else { return data }
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B else { return nil }
        let deflate = Data(bytes[10..<(bytes.count - 8)])
        #if canImport(Compression)
        let size = Int(UInt32(bytes[bytes.count - 4]) | UInt32(bytes[bytes.count - 3]) << 8
            | UInt32(bytes[bytes.count - 2]) << 16 | UInt32(bytes[bytes.count - 1]) << 24)
        var out = [UInt8](repeating: 0, count: size + 16)
        let n = deflate.withUnsafeBytes { src in
            compression_decode_buffer(&out, out.count, src.bindMemory(to: UInt8.self).baseAddress!, deflate.count, nil, COMPRESSION_ZLIB)
        }
        return Data(out[0..<n])
        #else
        // Stored blocks only (what the Linux build writes).
        var out = Data()
        var i = 0
        let d = [UInt8](deflate)
        while i + 5 <= d.count {
            let last = d[i] & 1
            let len = Int(d[i + 1]) | Int(d[i + 2]) << 8
            out.append(contentsOf: d[(i + 5)..<(i + 5 + len)])
            i += 5 + len
            if last == 1 { break }
        }
        return out
        #endif
    }
}

/// An engine on a temporary directory with a manual clock and a fake network.
final class Harness {
    let scheduler = ManualScheduler()
    let http = FakeHTTP()
    let dir: URL
    var device: DeviceInfo
    var logs: [String] = []
    private(set) var engine: Engine!
    var options = StartOptions(appId: "ATMONA02")

    init(file: StaticString = #file) {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("scruter-test-" + Random.hex(bytes: 6))
        device = DeviceInfo()
        device.bundleId = "fr.scruter.conformance"
        device.appVersion = "2.3.0"
        device.appBuild = "230"
        device.os = "18.2"
        device.model = "iPhone16,2"
        device.language = "fr"
        device.installSource = "app_store"
        device.containerCreatedMs = scheduler.now - 1000
    }

    /// What the person holding the phone answers to a team link.
    var teamAnswer = true

    @discardableResult
    func boot() -> Engine {
        let store = FileStore(directory: dir)
        let env = Environment(
            now: { [scheduler] in scheduler.now }, scheduler: scheduler, http: http, store: store,
            secrets: FileSecretStore(store: store), device: device)
        env.log.enabled = true
        env.log.sink = { [weak self] in self?.logs.append($0) }
        env.confirmTeamPhone = { [weak self] in $0(self?.teamAnswer ?? false) }
        engine = Engine(env: env, options: options)
        engine.start()
        return engine
    }

    /// Boots a wrapper's engine (`Scruter._setScreenListener`).
    func bootConfigFirst(listener: @escaping (ScruterBridgeScreen) -> Void) {
        let store = FileStore(directory: dir)
        let env = Environment(
            now: { [scheduler] in scheduler.now }, scheduler: scheduler, http: http, store: store,
            secrets: FileSecretStore(store: store), device: device)
        engine = Engine(env: env, options: options)
        engine.screenListener = listener
        engine.start()
    }

    func advance(seconds: Double) { scheduler.advance(Int64(seconds * 1000)) }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// Writes a batch for the protocol's validator (`node sdk/protocol/validate.mjs batch <file>`), when
    /// `SCRUTER_BATCH_OUT` names a directory.
    static func export(_ batch: JSON, name: String) {
        guard let out = ProcessInfo.processInfo.environment["SCRUTER_BATCH_OUT"] else { return }
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? batch.encoded().write(to: dir.appendingPathComponent(name + ".json"))
    }
}
