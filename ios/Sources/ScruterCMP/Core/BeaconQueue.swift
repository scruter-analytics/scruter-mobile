import Foundation

/// A beacon waiting to be sent: an opening's hit or a decision's proof (§3.10).
struct Beacon {
    var id: Int64
    /// `/cmp/hit` or `/cmp/consent`.
    var path: String
    var body: Data
    /// When it was made (ms): dropped 48 hours later, as the server could not place it any more.
    var created: Int64
    /// A proof: the stored choice it proves (`<consent id>.<decided at>`), whose pending flag goes on `202`.
    var proves: String?

    var json: JSONObject {
        var j: JSONObject = ["id": id, "path": path, "body": body.base64EncodedString(), "created": created]
        if let p = proves { j["proves"] = p }
        return j
    }

    @_optimize(size) init(id: Int64, path: String, body: Data, created: Int64, proves: String?) {
        self.id = id
        self.path = path
        self.body = body
        self.created = created
        self.proves = proves
    }

    @_optimize(size) init?(json j: JSONObject) {
        guard let id = j.int64("id"), let path = j.str("path"), let b = j.str("body").flatMap({ Data(base64Encoded: $0) }),
            let created = j.int64("created")
        else { return nil }
        self.init(id: id, path: path, body: b, created: created, proves: j.str("proves"))
    }
}

/// The persistent queue of hits and proofs (§3.10): the Analytics queue's rules (docs/MOBILE.md §3.15) on a small
/// scale. One request at a time, in order; `2xx` removes; no answer, `408`, `429` or `5xx` waits (exponential backoff
/// 5 s × 2ⁿ ± 20 %, at most 10 minutes, or the server's `Retry-After`); another `4xx` drops the beacon (sending it
/// again cannot fix it). Kept in a file, so a beacon survives the app being killed.
final class BeaconQueue {
    static let maxAgeMs: Int64 = 48 * 3600 * 1000
    /// A bound on the file (an opening a day offline for 48 hours is a handful): the oldest hits go first.
    static let maxItems = 500
    static let maxBackoff: Double = 600

    private let env: CMPEnvironment
    private let file = "beacons.json"
    private(set) var items: [Beacon]
    private var nextId: Int64
    private var inFlight = false
    private var attempt = 0
    private var retryAt: Int64 = 0
    /// The last failure had no answer: a returning network may try again at once (never before a `Retry-After`).
    private var offline = false
    private var timer: CMPScheduled?
    /// The base of the beacons' URLs (the configuration's `endpoint`).
    var endpoint: URL?
    /// A proof was acknowledged.
    var onAcknowledged: (String) -> Void = { _ in }

    @_optimize(size) init(env: CMPEnvironment) {
        self.env = env
        items = []
        nextId = 1
    }

    /// Reads the file (on the engine's queue, never at `start` on the main thread).
    @_optimize(size) func load() {
        items = (JSON.list(env.files.read(file)) ?? []).compactMap(Beacon.init(json:))
        nextId = (items.map { $0.id }.max() ?? 0) + 1
    }

    @_optimize(size) func add(path: String, body: Data, proves: String? = nil) {
        items.append(Beacon(id: nextId, path: path, body: body, created: env.now(), proves: proves))
        nextId += 1
        while items.count > BeaconQueue.maxItems {
            if let i = items.firstIndex(where: { $0.proves == nil }) { items.remove(at: i) } else { items.removeFirst() }
        }
        save()
        flush()
    }

    @_optimize(size) func hasProof(of key: String) -> Bool { items.contains { $0.proves == key } }

    @_optimize(size) func removeAll() {
        items = []
        save()
    }

    @_optimize(size) private func save() {
        if items.isEmpty { env.files.remove(file) } else { env.files.write(file, JSON.data(items.map { $0.json })) }
    }

    /// Sends what is due, one beacon at a time.
    @_optimize(size) func flush() {
        guard !inFlight, let base = endpoint else { return }
        let now = env.now()
        let before = items.count
        items.removeAll { now - $0.created > BeaconQueue.maxAgeMs }
        if items.count != before { save() }
        guard let next = items.first else { return }
        if now < retryAt {
            if timer == nil { schedule(after: Double(retryAt - now) / 1000) }
            return
        }
        inFlight = true
        let url = base.appendingPathComponent(String(next.path.dropFirst()))
        env.log.log("beacon", next.path)
        // `text/plain`, as the site script sends it (no CORS preflight on the web; the ingest reads JSON either way).
        let req = CMPRequest(method: "POST", url: url, headers: ["Content-Type": "text/plain;charset=UTF-8"], body: next.body)
        env.http.send(req) { [weak self] response in
            self?.handle(response, for: next)
        }
    }

    @_optimize(size) private func schedule(after seconds: Double) {
        timer?.cancel()
        timer = env.scheduler.schedule(after: seconds) { [weak self] in
            self?.timer = nil
            self?.flush()
        }
    }

    @_optimize(size) private func handle(_ response: CMPResponse?, for beacon: Beacon) {
        inFlight = false
        let status = response?.status ?? 0
        if (200..<300).contains(status) {
            attempt = 0
            retryAt = 0
            offline = false
            items.removeAll { $0.id == beacon.id }
            save()
            if let p = beacon.proves { onAcknowledged(p) }
            flush()
            return
        }
        if status == 0 || status == 408 || status == 429 || status >= 500 {
            var delay = min(BeaconQueue.maxBackoff, 5 * pow(2, Double(min(attempt, 10)))) * (0.8 + 0.4 * Double.random(in: 0..<1))
            if let ra = response?.headers["retry-after"].flatMap(Double.init), ra > 0 { delay = min(BeaconQueue.maxBackoff, ra) }
            attempt += 1
            offline = status == 0
            retryAt = env.now() + Int64(delay * 1000)
            env.log.log("beacon retried later, status", String(status))
            schedule(after: delay)
            return
        }
        env.log.log("beacon refused and dropped, status", String(status))
        items.removeAll { $0.id == beacon.id }
        save()
        // A refused proof cannot be acknowledged by resending it: the pending flag goes with it.
        if let p = beacon.proves { onAcknowledged(p) }
        flush()
    }

    /// The network came back, or the app returned to the foreground: try now, unless the server asked to wait.
    @_optimize(size) func retryNow() {
        guard offline || retryAt == 0 else { return }
        offline = false
        retryAt = 0
        attempt = 0
        timer?.cancel()
        timer = nil
        flush()
    }
}
