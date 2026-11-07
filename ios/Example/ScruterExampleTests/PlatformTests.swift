import SwiftUI
import UIKit
import XCTest

@_spi(ScruterBridge) @testable import ScruterAnalytics
@testable import ScruterExample

/// A fake Scruter server: full Advanced analytics collection, team phones on, every batch accepted.
final class FakeServer: HTTPClient {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    func send(_ request: HTTPRequest, completion: @escaping (HTTPResponse?) -> Void) {
        lock.lock()
        _requests.append(request)
        lock.unlock()
        let path = request.url.path
        if path.hasSuffix("/m/v1/config") {
            completion(HTTPResponse(status: 200, headers: [:], body: Data(#"{"v":1,"on":1,"e":"ex1","tz":"Europe/Paris","aa":100,"cr":1,"xs":[],"tp":1,"ttl":3600}"#.utf8)))
        } else {
            completion(HTTPResponse(status: 202, headers: [:], body: Data("{}".utf8)))
        }
    }

    /// Every event and analysed screen view sent so far.
    func items(_ key: String) -> [JSON] {
        requests.filter { $0.url.path.hasSuffix("/m/v1/batch") }.compactMap { r -> JSON? in
            // The test environment's gzip is the identity: bodies are plain JSON.
            r.body.flatMap { JSON.parse($0) }
        }.flatMap { $0[key]?.arrayValue ?? [] }
    }
}

enum SwiftUIElementsTests {
    static func scrollView(in v: UIView) -> UIScrollView? {
        if let s = v as? UIScrollView { return s }
        for c in v.subviews {
            if let s = scrollView(in: c) { return s }
        }
        return nil
    }
}

final class PlatformTests: XCTestCase {
    static let server = FakeServer()
    static var directory: URL!

    override class func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("scruter-example-" + UUID().uuidString)
        Runtime.shared.makeEnvironment = { _ in
            let store = FileStore(directory: directory)
            let device = Device.info(form: "phone", testBuild: false)
            return Environment(
                scheduler: QueueScheduler(queue: Runtime.shared.queue), http: server, store: store,
                secrets: FileSecretStore(store: store), device: device, gzip: { $0 })
        }
        Scruter.start(appId: "EXMPL01", debug: true)
        spin(1)
    }

    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func spin(_ seconds: TimeInterval) { Self.spin(seconds) }

    var window: UIWindow {
        let w = ApplePlatform.keyWindow() ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first!
        w.makeKeyAndVisible()
        return w
    }

    /// Screen names counted, sent or still queued.
    func screenNames() -> [String] {
        Runtime.shared.sync { $0?.flush() }
        spin(0.3)
        return Self.server.items("e").filter { $0["k"] == "screen" }.compactMap { $0["n"]?.stringValue }
    }

    func show(_ vc: UIViewController) -> UIWindow {
        let w = window
        w.rootViewController = vc
        w.layoutIfNeeded()
        spin(0.8)
        return w
    }

    func testAutomaticUIKitScreensAndNames() {
        let nav = UINavigationController(rootViewController: CatalogViewController())
        _ = show(nav)
        // The very first screen of a cold simulator can take seconds to appear.
        for _ in 0..<20 where screenNames().last != "Catalog" { spin(0.5) }
        XCTAssertEqual(screenNames().last, "Catalog")
        nav.pushViewController(ProductViewController(product: Product.all[0]), animated: false)
        spin(0.8)
        XCTAssertEqual(screenNames().last, "Product")
        let named = UIViewController()
        named.scruterScreenName = "Cart"
        nav.pushViewController(named, animated: false)
        spin(0.8)
        XCTAssertEqual(screenNames().last, "Cart")
        // An alert is never a screen.
        named.present(UIAlertController(title: "x", message: nil, preferredStyle: .alert), animated: false)
        spin(0.8)
        XCTAssertEqual(screenNames().last, "Cart")
        named.dismiss(animated: false)
        spin(0.3)
    }

    func testTapIdentityInAUIKitList() throws {
        let catalog = CatalogViewController()
        let nav = UINavigationController(rootViewController: catalog)
        _ = show(nav)
        let cell = try XCTUnwrap(catalog.tableView.cellForRow(at: IndexPath(row: 2, section: 0)) as? ProductCell)
        let point = cell.add.convert(CGPoint(x: cell.add.bounds.midX, y: cell.add.bounds.midY), to: nil)
        let id = try XCTUnwrap(TouchTracker.identify(hit: cell.add, point: point, root: catalog.view))
        XCTAssertEqual(id.selector, "#products/ProductCell/UIButton")
        XCTAssertEqual(id.index, 2)
        XCTAssertEqual(id.kind, .button)
        XCTAssertEqual(id.interactive, true)
        XCTAssertEqual(id.x, 50)
        // A label of the cell: the cell is the interactive target.
        let onLabel = try XCTUnwrap(TouchTracker.identify(hit: cell.name, point: cell.name.convert(.zero, to: nil), root: catalog.view))
        XCTAssertEqual(onLabel.selector, "#products/ProductCell")
        XCTAssertEqual(onLabel.kind, .cell)
    }

    func testStitchedCaptureOfAScrollView() throws {
        let nav = UINavigationController(rootViewController: ProductViewController(product: Product.all[1]))
        let w = show(nav)
        let shot = try XCTUnwrap(ScreenCapture.capture(window: w, maxHeight: 10_000, maxBytes: 2_000_000))
        let image = try XCTUnwrap(UIImage(data: shot.jpeg))
        XCTAssertGreaterThan(image.size.height * image.scale, w.bounds.height * 1.2, "the whole scroll content, stitched")
        XCTAssertLessThanOrEqual(shot.jpeg.count, 2_000_000)
        let nodes = try XCTUnwrap(shot.tree["nodes"]?.arrayValue)
        XCTAssertTrue(nodes.contains { $0["s"] == "#add_to_cart" && $0["l"] == "Add to cart" && $0["k"] == "button" })
        XCTAssertTrue(nodes.contains { $0["s"]?.stringValue?.hasPrefix("#gallery") == true })
        export(shot, name: "uikit-scroll")
    }

    func testCaptureMasksTextInputsAndMarkedViews() throws {
        let checkout = CheckoutViewController()
        let w = show(UINavigationController(rootViewController: checkout))
        checkout.name.text = "Morgan Smith"
        let shot = try XCTUnwrap(ScreenCapture.capture(window: w, maxHeight: 10_000, maxBytes: 2_000_000))
        let nodes = try XCTUnwrap(shot.tree["nodes"]?.arrayValue)
        let masked = nodes.filter { $0["m"] == 1 }
        XCTAssertGreaterThanOrEqual(masked.count, 6, "five text fields and the address preview")
        XCTAssertTrue(masked.allSatisfy { $0["l"] == nil }, "no label on a masked node")
        XCTAssertFalse(shot.tree.encodedString().contains("Morgan"))
        XCTAssertFalse(shot.tree.encodedString().contains("Potter"))
        // The pixels of the name field are the mask's colour.
        let image = try XCTUnwrap(UIImage(data: shot.jpeg)?.cgImage)
        let f = checkout.name.convert(checkout.name.bounds, to: nil)
        let px = pixel(image, x: Int((f.midX) * CGFloat(shot.scale)), y: Int((f.midY) * CGFloat(shot.scale)))
        XCTAssertLessThan(px, 60, "masked (dark) pixel")
        export(shot, name: "uikit-form")
    }

    func testSwiftUIMarkersGiveIdentitiesAndMasks() throws {
        let host = UIHostingController(rootView: NavigationView { ProductView(product: Product.all[2]) }.navigationViewStyle(.stack))
        let w = show(host)
        let markers = SwiftUIElements.markers(in: w)
        let add = try XCTUnwrap(markers.first { $0.marker.id == "addToCart" })
        XCTAssertTrue(markers.contains { $0.marker.mask })
        let center = add.convert(CGPoint(x: add.bounds.midX, y: add.bounds.midY), to: nil)
        let hit = try XCTUnwrap(w.hitTest(center, with: nil))
        let id = try XCTUnwrap(TouchTracker.identify(hit: hit, point: center, root: host.view))
        XCTAssertEqual(id.selector, "#addToCart")
        XCTAssertTrue(screenNames().contains("Product"))
        let shot = try XCTUnwrap(ScreenCapture.capture(window: w, maxHeight: 10_000, maxBytes: 2_000_000))
        let tree = shot.tree.encodedString()
        XCTAssertFalse(tree.contains("Potter"))
        let nodes = try XCTUnwrap(shot.tree["nodes"]?.arrayValue)
        XCTAssertTrue(nodes.contains { $0["s"] == "#addToCart" && $0["l"] == "Add to cart" }, tree)
        // A tap on what SwiftUI draws lands on the whole content, which is an element of the image.
        let scroll = try XCTUnwrap(SwiftUIElementsTests.scrollView(in: w))
        let text = CGPoint(x: 100, y: scroll.convert(CGPoint(x: 0, y: 330), to: nil).y)
        let plain = try XCTUnwrap(TouchTracker.identify(hit: host.view, point: text, root: host.view))
        XCTAssertNil(plain.interactive, "never a dead tap")
        let whole = try XCTUnwrap(nodes.first { $0["s"]?.stringValue == plain.selector && $0["k"] == "container" }, tree)
        XCTAssertEqual(Double(whole["h"]?.intValue ?? 0), Double(shot.height), accuracy: 2)
        // SwiftUI's backgrounds are transparent: the image shows the system's background, not black.
        let image = try XCTUnwrap(UIImage(data: shot.jpeg)?.cgImage)
        XCTAssertGreaterThan(pixel(image, x: image.width / 2, y: image.height - 4), 200)
        export(shot, name: "swiftui")
    }

    func testPlainSwiftUIButtonOutsideAScrollView() throws {
        let host = UIHostingController(rootView: Button("Plain") {}.padding(40))
        let w = show(host)
        let center = CGPoint(x: w.bounds.midX, y: w.bounds.midY)
        let hit = try XCTUnwrap(w.hitTest(center, with: nil))
        let id = try XCTUnwrap(TouchTracker.identify(hit: hit, point: center, root: host.view))
        XCTAssertNil(id.interactive, "SwiftUI does not tell: never a dead tap")
        XCTAssertEqual(id.x, 50)
        XCTAssertEqual(id.y, 50)
    }

    func testFormFieldsOfAUIKitForm() throws {
        let checkout = CheckoutViewController()
        _ = show(UINavigationController(rootViewController: checkout))
        spin(0.8)
        checkout.postalCode.becomeFirstResponder()
        spin(0.2)
        checkout.postalCode.insertText("750")
        spin(0.2)
        checkout.postalCode.resignFirstResponder()
        Scruter.fieldError("postalCode", kind: .format)
        spin(0.2)
        // Leaving the screen sends the analysed state.
        _ = show(UINavigationController(rootViewController: CatalogViewController()))
        _ = screenNames()
        let views = Self.server.items("x").filter { $0["n"] == "Checkout" }
        let form = try XCTUnwrap(views.last?["f"]?.arrayValue?.first { $0["s"] == "Delivery" })
        let keys = (form["fd"]?.arrayValue ?? []).compactMap { $0.arrayValue?.first?.stringValue }
        XCTAssertTrue(keys.contains("postalCode"), "\(keys)")
        XCTAssertTrue(keys.contains("name"), "\(keys)")
        XCTAssertFalse(keys.contains { $0.lowercased().contains("card") || $0.lowercased().contains("password") }, "\(keys)")
        XCTAssertEqual(keys.count, 4, "\(keys)")
        XCTAssertEqual(form["b"], 1)
        XCTAssertEqual(form["lf"], "postalCode")
    }

    func testCrashReportWriterOnThisDevice() throws {
        XCTAssertNotEqual(scruter_crash_installed(), 0)
        let store = try XCTUnwrap(Runtime.shared.sync { $0?.env.store })
        XCTAssertEqual(scruter_crash_write_test_report("Test"), 0)
        let data = try XCTUnwrap(store.read("crash.report"))
        store.write("crash.report", Data())
        let raw = try XCTUnwrap(CrashReport.parseRaw(data))
        XCTAssertEqual(raw.kind, "nonfatal")
        XCTAssertGreaterThan(raw.threads.first?.addresses.count ?? 0, 2)
        XCTAssertTrue(raw.images.contains { $0.name == "ScruterExample" && $0.inApp })
        XCTAssertTrue(raw.images.contains { $0.name == "UIKitCore" && !$0.inApp })
        XCTAssertNotNil(raw.context["s"]?.stringValue, "the context carries the session")
        let item = try XCTUnwrap(CrashReport.item(from: raw))
        XCTAssertGreaterThan(item["img"]?.arrayValue?.count ?? 0, 0)
    }

    func testDeviceFactsOnTheSimulator() {
        let d = Device.info(form: "phone", testBuild: false)
        XCTAssertEqual(d.buildKind, "debug")
        XCTAssertTrue(d.isDebugBuild)
        XCTAssertTrue(d.model.hasPrefix("iPhone") || d.model.hasPrefix("iPad"), d.model)
        XCTAssertEqual(d.bundleId, "net.scruter.example")
        XCTAssertNotNil(Device.containerCreated())
    }

    func testIdentityTime() {
        for (rows, budget) in [(60, 6.0), (400, 30.0)] {
            let root = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 4000))
            var last: UIView = root
            for i in 0..<rows {
                let row = UIView()
                for j in 0..<4 {
                    let v: UIView = j == 1 ? UIButton(type: .system) : (j == 2 ? UIImageView() : UILabel())
                    if j == 1 && i % 2 == 0 { v.accessibilityIdentifier = "buy" }
                    row.addSubview(v)
                    last = v
                }
                root.addSubview(row)
            }
            var times: [Double] = []
            var selector = ""
            for _ in 0..<15 {
                let start = CFAbsoluteTimeGetCurrent()
                selector = Identity.identify(last, root: root).selector
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            let ms = times.sorted()[times.count / 2]
            print("[budget] identity of a tap, \(rows * 5) views: \(String(format: "%.2f", ms)) ms (median, CI simulator)")
            XCTAssertFalse(selector.isEmpty)
            XCTAssertLessThan(ms, budget)
        }
    }

    func testABridgeInspectorNamesAViewAndDecidesWhatItIs() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let cell = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        let hidden = UIView(frame: CGRect(x: 0, y: 100, width: 300, height: 100))
        let masked = UIView(frame: CGRect(x: 0, y: 200, width: 300, height: 100))
        [cell, hidden, masked].forEach(host.addSubview)
        Elements.inspector = { v in
            let e = BridgeElement()
            switch v {
            case cell:
                e.id = "from_inspector"
                e.index = 7
                e.interactive = true
                e.kind = "cell"
            case hidden: e.ignore = true
            case masked:
                e.mask = true
                e.form = "Delivery"
            default: return nil
            }
            return e
        }
        defer { Elements.inspector = nil }
        let id = try XCTUnwrap(TouchTracker.identify(hit: cell, point: CGPoint(x: 150, y: 50), root: host))
        // An item: the list's part + its own (§3.5).
        XCTAssertEqual(id.selector, "UIView[other]/#from_inspector")
        XCTAssertEqual(id.index, 7)
        XCTAssertEqual(id.kind, .cell)
        XCTAssertEqual(id.interactive, true)
        XCTAssertNil(TouchTracker.identify(hit: hidden, point: CGPoint(x: 150, y: 150), root: host))
        XCTAssertTrue(Elements.isMasked(masked))
        XCTAssertEqual(masked.scruterForm, "Delivery")
    }

    func testALabelMadeFromAMaskedElementIsNotSent() {
        let host = UIView()
        host.accessibilityLabel = "Morgan Smith"
        let inner = UIView()
        host.addSubview(inner)
        Elements.inspector = { v in
            let e = BridgeElement()
            e.mask = v === inner
            return e
        }
        defer { Elements.inspector = nil }
        XCTAssertNil(Elements.label(of: host))
        inner.removeFromSuperview()
        XCTAssertEqual(Elements.label(of: host), "Morgan Smith")
    }

    func testABridgeNamesItsOwnRoutes() {
        let nav = UINavigationController(rootViewController: CatalogViewController())
        Runtime.shared.bridge = ("react_native", "1.0.0")
        defer { Runtime.shared.bridge = nil }
        _ = show(nav)
        let before = screenNames().count
        Scruter._screen("Home", forward: true)
        spin(0.5)
        let names = screenNames()
        XCTAssertEqual(names.suffix(names.count - before), ["Home"])
    }

    func testOptOutSwitch() {
        Scruter.optOut()
        XCTAssertTrue(Scruter.isOptedOut)
        Scruter.optIn()
        XCTAssertFalse(Scruter.isOptedOut)
        spin(0.3)
    }

    // MARK: Helpers

    private func pixel(_ image: CGImage, x: Int, y: Int) -> Int {
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return 255 }
        let bpp = image.bitsPerPixel / 8
        let offset = y * image.bytesPerRow + x * bpp
        guard offset + 2 < CFDataGetLength(data) else { return 255 }
        return (Int(ptr[offset]) + Int(ptr[offset + 1]) + Int(ptr[offset + 2])) / 3
    }

    /// Writes the team upload's parts for `sdk/protocol/validate.mjs` when SCRUTER_BATCH_OUT is set.
    private func export(_ shot: ScreenCapture.Shot, name: String) {
        guard let out = ProcessInfo.processInfo.environment["SCRUTER_BATCH_OUT"] else { return }
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = Team.meta(screen: name, device: Device.info(form: "phone", testBuild: false), width: shot.width, height: shot.height, scale: shot.scale, takenAt: Date())
        try? meta.encoded().write(to: dir.appendingPathComponent("team-meta-\(name).json"))
        try? shot.tree.encoded().write(to: dir.appendingPathComponent("team-tree-\(name).json"))
        try? shot.jpeg.write(to: dir.appendingPathComponent("team-image-\(name).jpg"))
    }
}
