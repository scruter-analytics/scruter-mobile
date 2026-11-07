import Flutter
import UIKit

// Swift Package Manager: the SDK is a module of its own. CocoaPods: its sources are compiled into this pod (ios/vendor).
#if canImport(ScruterAnalytics)
@_spi(ScruterBridge) import ScruterAnalytics
#endif

/// The bridge between `package:scruter_flutter` and the native SDK (docs/MOBILE.md §17): the SDK keeps sessions,
/// transport, native crashes, openings and team phones; the Dart side measures the screens. The team phones' strips,
/// already masked in Dart, are assembled and encoded here, on one background queue.
public final class ScruterFlutterPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel
    private let imageQueue = DispatchQueue(label: "net.scruter.flutter.image", qos: .utility)
    private var image: CGContext?
    private var imageWidth = 0
    private var started = false
    /// What opened the app before `Scruter.start`, which runs in Dart.
    private var pendingLinks: [URL] = []
    private var pendingShortcut = false

    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "net.scruter/flutter", binaryMessenger: registrar.messenger())
        let plugin = ScruterFlutterPlugin(channel: channel)
        registrar.addMethodCallDelegate(plugin, channel: channel)
        registrar.addApplicationDelegate(plugin)
    }

    // MARK: Openings

    public func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [AnyHashable: Any] = [:]
    ) -> Bool {
        if let url = launchOptions[UIApplication.LaunchOptionsKey.url] as? URL { pendingLinks.append(url) }
        if launchOptions[UIApplication.LaunchOptionsKey.shortcutItem] != nil { pendingShortcut = true }
        return true
    }

    public func application(
        _ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        forward(url)
    }

    public func application(
        _ application: UIApplication, continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([Any]) -> Void
    ) -> Bool {
        if let url = userActivity.webpageURL { _ = forward(url) }
        return false
    }

    public func application(
        _ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) -> Bool {
        Scruter.openedFromShortcut()
        return false
    }

    /// `true` for Scruter's own link (a team phone's QR code): it never reaches the app's router.
    private func forward(_ url: URL) -> Bool {
        if started { return Scruter.handle(url: url) }
        pendingLinks.append(url)
        return url.scheme?.hasPrefix("scruter-") ?? false
    }

    // MARK: Channel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let a = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "start":
            start(a)
            result(nil)
        case "screen":
            if let n = a["name"] as? String { Scruter.screen(n) }
            result(nil)
        case "track":
            guard let n = a["name"] as? String else { return result(nil) }
            Scruter.track(
                n, props: a["props"] as? [String: Any], revenue: (a["revenue"] as? NSNumber)?.doubleValue,
                currency: a["currency"] as? String)
            result(nil)
        case "screenEnd":
            if let s = a["session"] as? String, let n = a["name"] as? String, let ms = a["ms"] as? NSNumber,
                let d = a["depth"] as? NSNumber
            {
                Scruter._screenEnd(session: s, name: n, engagedMs: ms.int64Value, depth: d.intValue)
            }
            result(nil)
        case "analysed":
            if let s = a["session"] as? String, let j = a["json"] as? String {
                Scruter._analysedScreen(session: s, json: Data(j.utf8))
            }
            result(nil)
        case "reportError":
            reportError(a)
            result(nil)
        case "flush":
            Scruter.flush()
            result(nil)
        case "link":
            if let s = a["url"] as? String, let u = URL(string: s) { _ = forward(u) }
            result(nil)
        case "openedFromNotification":
            Scruter.openedFromNotification()
            result(nil)
        case "optOut":
            Scruter.optOut()
            result(nil)
        case "optIn":
            Scruter.optIn()
            result(nil)
        case "ignoreThisDevice":
            if a["ignore"] as? Bool ?? true { Scruter.ignoreThisDevice() } else { Scruter.stopIgnoringThisDevice() }
            result(nil)
        case "isOptedOut":
            // Waits for the SDK's first load: not on the main thread.
            DispatchQueue.global(qos: .utility).async {
                let v = Scruter.isOptedOut
                DispatchQueue.main.async { result(v) }
            }
        case "isDeviceIgnored":
            DispatchQueue.global(qos: .utility).async {
                let v = Scruter.isDeviceIgnored
                DispatchQueue.main.async { result(v) }
            }
        case "isTeamPhone":
            DispatchQueue.global(qos: .utility).async {
                let v = Scruter.isTeamPhone
                DispatchQueue.main.async { result(v) }
            }
        case "leaveTeamMode":
            Scruter.leaveTeamMode()
            result(nil)
        case "imageBegin":
            imageBegin(a, result)
        case "imageStrip":
            imageStrip(a, result)
        case "imageFinish":
            imageFinish(a, result)
        case "imageCancel":
            imageQueue.async { self.image = nil }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func start(_ a: [String: Any]) {
        guard let appId = a["appId"] as? String else { return }
        Scruter._setBridge(sdk: "flutter", version: a["version"] as? String ?? "0")
        Scruter._setScreenListener { [weak self] s in
            let m: [String: Any] = [
                "session": s.session, "name": s.name, "startMs": s.startMs, "analysed": s.analysed, "capture": s.capture,
                "maxBytes": s.maxBytes, "maxHeight": s.maxHeight,
            ]
            DispatchQueue.main.async { self?.channel.invokeMethod("screenStarted", arguments: m) }
        }
        Scruter.start(
            appId: appId, debugKey: a["debugKey"] as? String, debug: a["debug"] as? Bool ?? false,
            testBuild: a["testBuild"] as? Bool ?? false, endpoint: (a["endpoint"] as? String).flatMap(URL.init(string:)),
            apiEndpoint: (a["apiEndpoint"] as? String).flatMap(URL.init(string:)))
        started = true
        for url in pendingLinks { Scruter.handle(url: url) }
        pendingLinks = []
        if pendingShortcut { Scruter.openedFromShortcut() }
        pendingShortcut = false
    }

    private func reportError(_ a: [String: Any]) {
        let frames: [[String: Any]] = (a["frames"] as? [[String: Any]] ?? []).map { f in
            var o = f
            if let ia = f["ia"] as? Bool {
                if ia { o["ia"] = 1 } else { o.removeValue(forKey: "ia") }
            }
            return o
        }
        var ids: [String: String] = [:]
        if let b = a["buildId"] as? String { ids["bld"] = b }
        Scruter._reportError(
            kind: a["fatal"] as? Bool ?? false ? "crash" : "nonfatal", src: "dart", type: a["type"] as? String ?? "Error",
            reason: a["reason"] as? String ?? "", frames: frames, debugIds: ids,
            images: a["images"] as? [[String: String]] ?? [])
    }

    // MARK: Screen images

    private func imageBegin(_ a: [String: Any], _ result: @escaping FlutterResult) {
        let width = a["width"] as? Int ?? 0
        let rows = a["rows"] as? Int ?? 0
        imageQueue.async {
            self.imageWidth = width
            self.image = CGContext(
                data: nil, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            DispatchQueue.main.async { result(nil) }
        }
    }

    private func imageStrip(_ a: [String: Any], _ result: @escaping FlutterResult) {
        guard let rgba = a["rgba"] as? FlutterStandardTypedData, let y = a["y"] as? Int, let rows = a["rows"] as? Int,
            let width = a["width"] as? Int
        else { return result(nil) }
        imageQueue.async {
            if let c = self.image, let base = c.data, width <= self.imageWidth, y >= 0, y + rows <= c.height {
                rgba.data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    guard let from = src.baseAddress else { return }
                    for r in 0..<rows {
                        memcpy(base + (y + r) * c.bytesPerRow, from + r * width * 4, width * 4)
                    }
                }
            }
            DispatchQueue.main.async { result(nil) }
        }
    }

    private func imageFinish(_ a: [String: Any], _ result: @escaping FlutterResult) {
        let screen = a["screen"] as? String ?? ""
        let tree = Data((a["tree"] as? String ?? "").utf8)
        let rows = a["rows"] as? Int ?? 0
        let scale = (a["scale"] as? NSNumber)?.doubleValue ?? 1
        let maxBytes = a["maxBytes"] as? Int ?? 2_000_000
        imageQueue.async {
            defer {
                self.image = nil
                DispatchQueue.main.async { result(nil) }
            }
            guard let c = self.image, rows > 0, rows <= c.height,
                let full = c.makeImage(),
                let cropped = full.cropping(to: CGRect(x: 0, y: 0, width: c.width, height: rows))
            else { return }
            let width = c.width
            let ui = UIImage(cgImage: cropped)
            // Quality 0.8, lowered by steps to fit the server's limit (docs/MOBILE.md §3.12).
            var quality: CGFloat = 0.8
            while quality >= 0.3 {
                if let jpeg = ui.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                    Scruter._teamImage(screen: screen, jpeg: jpeg, tree: tree, width: width, height: rows, scale: scale)
                    return
                }
                quality -= 0.1
            }
        }
    }
}
