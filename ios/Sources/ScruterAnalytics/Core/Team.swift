import Foundation

/// Team phones (docs/MOBILE.md §3.12): registration by QR code or debug key, the team configuration, and the uploads
/// of screen images. Only these phones ever capture a screen; a user's phone never does.
final class Team {
    static let tokenKey = "team_device_token"

    let env: Environment
    let options: StartOptions
    private(set) var deviceToken: String?
    private var allowed = false
    private(set) var captured: [String] = []
    private(set) var retake: [String] = []
    private(set) var maxBytes = 2_000_000
    private(set) var maxHeight = 10_000
    private var configLoaded = false
    private var configAt: Int64 = 0
    private var ttl = 600
    private var takenThisRun: [String] = []
    private var inProgress: [String] = []
    private var registering = false
    private var configuring = false
    /// Called on the engine's queue when the phone joins or leaves team mode.
    var onChange: ((Bool) -> Void)?

    init(env: Environment, options: StartOptions) {
        self.env = env
        self.options = options
        deviceToken = env.secrets.get(Team.tokenKey)
    }

    var isActive: Bool { deviceToken != nil }

    func start(config: RemoteConfig, device: DeviceInfo) {
        allowed = config.teamPhones || config.fetchedAt == 0
        if deviceToken == nil, let key = options.debugKey {
            // A debug key is used only by a build the SDK recognises as a debug build: a release build that ships it
            // by mistake never captures anything.
            if device.isDebugBuild && device.buildKind == "debug" && StartOptions.isValidDebugKey(key) {
                register(body: ["debug_key": .string(key)], device: device)
            } else if !device.isDebugBuild {
                env.log.log("debugKey ignored: not a debug build")
            } else {
                env.log.log("debugKey ignored: not a valid scr_dbg_ key")
            }
        }
        if isActive { fetchConfig() }
    }

    func configure(config: RemoteConfig) {
        allowed = config.teamPhones
    }

    // MARK: Registration

    func register(token: String, device: DeviceInfo) {
        register(body: ["token": .string(token)], device: device)
    }

    private func register(body extra: Fields, device: DeviceInfo) {
        guard !registering else { return }
        var o = extra
        o["app"] = .string(options.appId)
        o["platform"] = .string(device.platform)
        o["model"] = .string(Text.cut(device.model.isEmpty ? "unknown" : device.model, max: 60))
        o["os"] = .string(Text.cut(device.os.isEmpty ? "0" : device.os, max: 20))
        o["form"] = .string(device.form)
        o["app_version"] = .string(Text.cut(device.appVersion.isEmpty ? "0" : device.appVersion, max: 40))
        o["build_kind"] = .string(device.buildKind)
        registering = true
        let url = options.apiEndpoint.appendingPathComponent("m/v1/team/register")
        env.http.send(
            HTTPRequest(
                method: "POST", url: url, headers: ["Content-Type": "application/json"], body: JSON.object(o).encoded())
        ) { [weak self] r in
            guard let self = self else { return }
            self.registering = false
            guard r?.status == 201, let j = r.flatMap({ JSON.parse($0.body) }),
                let t = j.str("device_token"), t.hasPrefix("scr_tp_")
            else {
                self.env.log.log("team phone registration refused, status", String(r?.status ?? 0))
                return
            }
            self.deviceToken = t
            self.env.secrets.set(Team.tokenKey, t)
            self.env.log.log("this phone is a team phone:", j.str("name") ?? "")
            self.onChange?(true)
            self.fetchConfig()
        }
    }

    /// Leaves team mode: the token is deleted (a revoked phone, or the app asks).
    func leave() {
        deviceToken = nil
        env.secrets.set(Team.tokenKey, nil)
        captured = []
        retake = []
        configLoaded = false
        onChange?(false)
        env.log.log("this phone left team mode")
    }

    // MARK: Team configuration

    func fetchConfig() {
        guard let token = deviceToken, !configuring else { return }
        var c = URLComponents(
            url: options.apiEndpoint.appendingPathComponent("m/v1/team/config"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "av", value: env.device.appVersion), URLQueryItem(name: "p", value: env.device.platform),
            URLQueryItem(name: "f", value: env.device.form),
        ]
        guard let url = c.url else { return }
        configuring = true
        env.http.send(HTTPRequest(method: "GET", url: url, headers: ["Authorization": "Bearer " + token], body: nil)) {
            [weak self] r in
            guard let self = self else { return }
            self.configuring = false
            if r?.status == 401 {
                self.leave()
                return
            }
            guard r?.status == 200, let j = r.flatMap({ JSON.parse($0.body) }) else { return }
            self.captured = (j.list("captured") ?? []).compactMap { $0.stringValue }
            self.retake = (j.list("retake") ?? []).compactMap { $0.stringValue }
            self.maxBytes = max(100_000, min(2_000_000, j.int("max_bytes") ?? 2_000_000))
            self.maxHeight = max(1000, min(10_000, j.int("max_height") ?? 10_000))
            self.ttl = max(60, min(86_400, j.int("ttl") ?? 600))
            self.configLoaded = true
            self.configAt = self.env.now()
            // Retakes asked from the console are taken again even if this run already took them.
            self.takenThisRun = self.takenThisRun.filter { !self.retake.contains($0) }
        }
    }

    /// Whether a screen that just appeared should be captured: no image yet for this version (or a retake asked),
    /// at most once per screen and process run.
    func wants(screen: String) -> Bool {
        guard isActive, allowed else { return false }
        if configLoaded && env.now() - configAt > Int64(ttl) * 1000 { fetchConfig() }
        guard configLoaded, !takenThisRun.contains(screen), !inProgress.contains(screen) else { return false }
        return retake.contains(screen) || !captured.contains(screen)
    }

    // MARK: Upload

    /// Uploads a screen image and its element tree (`POST /m/v1/team/screens`, multipart).
    func upload(screen: String, meta: JSON, jpeg: Data, tree: JSON, completion: ((Bool) -> Void)? = nil) {
        guard let token = deviceToken, jpeg.count <= maxBytes else {
            completion?(false)
            return
        }
        inProgress.append(screen)
        let boundary = "scruter-" + Random.hex(bytes: 12)
        let body = Team.multipart(
            boundary: boundary,
            parts: [
                ("meta", nil, "application/json", meta.encoded()),
                ("image", "screen.jpg", "image/jpeg", jpeg),
                ("tree", nil, "application/json", tree.encoded()),
            ])
        let url = options.apiEndpoint.appendingPathComponent("m/v1/team/screens")
        env.http.send(
            HTTPRequest(
                method: "POST", url: url,
                headers: [
                    "Authorization": "Bearer " + token, "Content-Type": "multipart/form-data; boundary=" + boundary,
                ], body: body)
        ) { [weak self] r in
            guard let self = self else { return }
            self.inProgress.removeAll { $0 == screen }
            let status = r?.status ?? 0
            if status == 202 || status == 200 {
                self.takenThisRun.append(screen)
                self.captured.append(screen)
                self.retake.removeAll { $0 == screen }
                self.env.log.log("screen image uploaded:", screen)
                completion?(true)
                return
            }
            if status == 401 { self.leave() }
            if status == 400 || status == 403 || status == 413 || status == 422 { self.takenThisRun.append(screen) }
            self.env.log.log("screen image refused:", screen, String(status))
            completion?(false)
        }
    }

    static func multipart(boundary: String, parts: [(String, String?, String, Data)]) -> Data {
        var d = Data()
        for (name, file, type, data) in parts {
            d.append(Text.utf8("--\(boundary)\r\n"))
            var disposition = "Content-Disposition: form-data; name=\"\(name)\""
            if let f = file { disposition += "; filename=\"\(f)\"" }
            d.append(Text.utf8("\(disposition)\r\nContent-Type: \(type)\r\n\r\n"))
            d.append(data)
            d.append(Text.utf8("\r\n"))
        }
        d.append(Text.utf8("--\(boundary)--\r\n"))
        return d
    }

    /// The `meta` part of an upload.
    static func meta(
        screen: String, device: DeviceInfo, width: Int, height: Int, scale: Double, takenAt: Date
    ) -> JSON {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return [
            "screen": .string(Text.cut(screen, max: 120)), "app_version": .string(Text.cut(device.appVersion, max: 40)),
            "platform": .string(device.platform), "form": .string(device.form), "width": .int(Int64(width)),
            "height": .int(Int64(height)), "scale": .double(scale), "taken_at": .string(f.string(from: takenAt)),
            "model": .string(Text.cut(device.model, max: 60)), "os": .string(Text.cut(device.os, max: 20)),
        ]
    }
}
