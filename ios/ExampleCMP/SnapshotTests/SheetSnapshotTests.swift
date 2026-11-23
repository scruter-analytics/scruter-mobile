import SwiftUI
import UIKit
import XCTest

@testable import ScruterCMP

/// Snapshot tests of the sheet (docs/CMP-MOBILE.md §9.2): each layer, light and dark, iPhone and iPad, French, German,
/// Arabic, 200 % text, compared with the references in `ExampleCMP/Snapshots/` (recorded on CI's simulators).
/// `SCRUTER_SNAPSHOT_RECORD=1` writes the references instead; every image is also written to `SCRUTER_SNAPSHOT_OUT`.
final class SheetSnapshotTests: XCTestCase {
    static let snapshots = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Snapshots")
    static let heroURL = "https://cdn.scruter.net/cmp/media/hero.jpg"
    static let iconURL = "https://cdn.scruter.net/cmp/assets/logos/icon.png"

    enum Layer { case first, steps, preferences, partners, vendor, ac }

    struct Case {
        var name: String
        var pad = false
        var lang = "fr"
        var dark = false
        var typeSize: DynamicTypeSize = .large
        var layer: Layer = .first
        /// The site's IAB TCF on (`bodies/config-tcf.json`, the kit's GVL 186 vendors; docs/CMP-MOBILE.md §6).
        var tcf = false
        var edit: (inout [String: Any]) -> Void = { _ in }
    }

    static let cases: [Case] = [
        Case(name: "iphone-fr-light-first"),
        Case(name: "iphone-fr-dark-first", dark: true),
        Case(name: "iphone-fr-light-steps", layer: .steps),
        Case(name: "iphone-fr-dark-steps", dark: true, layer: .steps),
        Case(name: "iphone-fr-light-preferences", layer: .preferences),
        Case(name: "iphone-fr-dark-preferences", dark: true, layer: .preferences),
        Case(name: "iphone-de-light-first", lang: "de"),
        Case(name: "iphone-ar-light-first", lang: "ar"),
        Case(name: "iphone-ar-light-steps", lang: "ar", layer: .steps),
        Case(name: "iphone-fr-light-first-200", typeSize: .accessibility2),
        Case(name: "iphone-fr-light-steps-200", typeSize: .accessibility2, layer: .steps),
        Case(name: "iphone-fr-light-panel", edit: { ui in ui["hero"] = nil }),
        Case(name: "iphone-fr-light-free-nopanel", edit: { ui in
            ui["hero"] = nil
            ui["no_panel"] = true
            ui["close_link"] = false
            ui["branding"] = true
        }),
        Case(name: "iphone-fr-light-two-buttons", edit: { ui in ui["buttons"] = "two" }),
        Case(name: "ipad-fr-light-first", pad: true),
        Case(name: "ipad-fr-dark-first", pad: true, dark: true),
        Case(name: "ipad-fr-light-steps", pad: true, layer: .steps),
        Case(name: "ipad-fr-light-preferences", pad: true, layer: .preferences),
        Case(name: "ipad-de-light-first-200", pad: true, lang: "de", typeSize: .accessibility2),
        // The IAB TCF layers (boards M7 and M15).
        Case(name: "iphone-fr-light-tcf-first", tcf: true),
        Case(name: "iphone-fr-dark-tcf-first", dark: true, tcf: true),
        Case(name: "iphone-fr-light-tcf-step", layer: .steps, tcf: true),
        Case(name: "iphone-fr-dark-tcf-step", dark: true, layer: .steps, tcf: true),
        Case(name: "iphone-fr-light-tcf-partners", layer: .partners, tcf: true),
        Case(name: "iphone-fr-light-tcf-vendor", layer: .vendor, tcf: true),
        // One of Google's other ad tech providers (Additional Consent, board M7).
        Case(name: "iphone-fr-light-tcf-ac", layer: .ac, tcf: true),
        Case(name: "iphone-fr-dark-tcf-vendor", dark: true, layer: .vendor, tcf: true),
        Case(name: "iphone-fr-light-tcf-preferences", layer: .preferences, tcf: true),
        Case(name: "iphone-de-light-tcf-first", lang: "de", tcf: true),
        Case(name: "iphone-de-light-tcf-step", lang: "de", layer: .steps, tcf: true),
        Case(name: "iphone-ar-light-tcf-first", lang: "ar", tcf: true),
        Case(name: "iphone-ar-light-tcf-partners", lang: "ar", layer: .partners, tcf: true),
        Case(name: "iphone-fr-light-tcf-first-200", typeSize: .accessibility2, tcf: true),
        Case(name: "iphone-fr-light-tcf-step-200", typeSize: .accessibility2, layer: .steps, tcf: true),
        Case(name: "ipad-fr-light-tcf-first", pad: true, tcf: true),
        Case(name: "ipad-fr-dark-tcf-first", pad: true, dark: true, tcf: true),
        Case(name: "ipad-fr-light-tcf-step", pad: true, layer: .steps, tcf: true),
        Case(name: "ipad-fr-light-tcf-partners", pad: true, layer: .partners, tcf: true),
        Case(name: "ipad-fr-light-tcf-vendor", pad: true, layer: .vendor, tcf: true),
    ]

    override func setUp() {
        CMPMedia.shared.fixtures = [SheetSnapshotTests.heroURL: Fixtures.hero(), SheetSnapshotTests.iconURL: Fixtures.icon()]
    }

    func testSheets() throws {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let selected = SheetSnapshotTests.cases.filter { $0.pad == pad }
        XCTAssertFalse(selected.isEmpty)
        var failures: [String] = []
        for c in selected {
            let model = try Fixtures.model(for: c)
            let image = try render(model, c)
            if let f = compare(image, c.name) { failures.append(f) }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testToast() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let model = try Fixtures.model(for: Case(name: "toast"))
        let view = ZStack { FakeApp(); CMPToast(model: model) }
        let image = try snapshot(AnyView(view), dark: false)
        if let f = compare(image, "iphone-fr-light-toast") { XCTFail(f) }
    }

    private func render(_ model: SheetModel, _ c: Case) throws -> (UIImage, UIImage) {
        let state = CMPSheetState(model: model, shown: true)
        if c.layer == .steps { state.step = 1 }
        if c.layer == .steps { state.granted = c.tcf ? ["advertising"] : ["analytics"] }
        if c.layer == .partners { state.step = model.purposes.count }
        if c.layer == .vendor {
            state.step = model.purposes.count
            state.page = .vendor(755)
        }
        if c.layer == .ac {
            state.step = model.purposes.count
            state.page = .ac(108)
        }
        let view = ZStack {
            FakeApp()
            CMPSheetRoot(state: state)
        }
        .environment(\.dynamicTypeSize, c.typeSize)
        return try snapshot(AnyView(view), dark: c.dark)
    }

    /// The screen at 1× (the reference, small in the repository) and at 2× (the screenshot written out).
    private func snapshot(_ view: AnyView, dark: Bool) throws -> (UIImage, UIImage) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        // Two layout passes: the sheet sizes its scroll view to its content.
        for _ in 0..<6 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        func render(_ scale: CGFloat) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.preferredRange = .standard
            return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
        return (render(1), render(2))
    }

    /// `nil` when the image matches its reference (≤ 0.5 % of pixels differing by more than 8 / 255 on a channel).
    private func compare(_ images: (UIImage, UIImage), _ name: String) -> String? {
        let image = images.0
        let png = image.pngData()!
        let env = ProcessInfo.processInfo.environment
        if let out = env["SCRUTER_SNAPSHOT_OUT"] {
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try? images.1.pngData()?.write(to: URL(fileURLWithPath: out).appendingPathComponent(name + ".png"))
        }
        let ref = SheetSnapshotTests.snapshots.appendingPathComponent(name + ".png")
        if env["SCRUTER_SNAPSHOT_RECORD"] == "1" {
            try? FileManager.default.createDirectory(at: SheetSnapshotTests.snapshots, withIntermediateDirectories: true)
            try? png.write(to: ref)
            return nil
        }
        guard let refData = try? Data(contentsOf: ref), let refImage = UIImage(data: refData) else {
            return name + ": no reference (record with SCRUTER_SNAPSHOT_RECORD=1)"
        }
        guard let a = Pixels(image), let b = Pixels(refImage), a.width == b.width, a.height == b.height else {
            return name + ": size differs from the reference"
        }
        var differing = 0
        for i in stride(from: 0, to: a.bytes.count, by: 4) {
            for k in 0..<3 where abs(Int(a.bytes[i + k]) - Int(b.bytes[i + k])) > 8 {
                differing += 1
                break
            }
        }
        let share = Double(differing) / Double(a.width * a.height)
        return share <= 0.005 ? nil : name + String(format: ": %.2f %% of the pixels differ", share * 100)
    }
}

/// RGBA bytes of an image.
struct Pixels {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        width = cg.width
        height = cg.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }
}

/// An app behind the sheet, as on the boards.
struct FakeApp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("atelier mona").font(.system(size: 22, weight: .bold, design: .serif))
            Text("Des bols qu’on a envie de garder.").font(.system(size: 30, weight: .bold, design: .serif))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(0..<6) { _ in RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.94, green: 0.89, blue: 0.84)).frame(height: 150) }
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.98, green: 0.97, blue: 0.96).ignoresSafeArea())
    }
}

enum Fixtures {
    static func hero() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 960, height: 400)).image { ctx in
            let c = ctx.cgContext
            let colors = [UIColor(red: 0.86, green: 0.72, blue: 0.58, alpha: 1).cgColor, UIColor(red: 0.55, green: 0.36, blue: 0.26, alpha: 1).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 960, y: 400), options: [])
            for (x, w, col) in [(180.0, 260.0, 0.93), (470.0, 200.0, 0.82), (700.0, 220.0, 0.97)] {
                UIColor(white: col, alpha: 1).setFill()
                c.fillEllipse(in: CGRect(x: x, y: 170, width: w, height: w * 0.55))
            }
        }
    }

    static func icon() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 192, height: 192)).image { ctx in
            UIColor(red: 0.98, green: 0.96, blue: 0.93, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 192, height: 192))
            UIColor(red: 0.71, green: 0.27, blue: 0.12, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 36, y: 60, width: 120, height: 80))
        }
    }

    static let ar: [String: Any] = [
        "title": "بياناتك، اختياراتك", "message": "تستخدم أتيليه مونا وشركاؤها أدوات تتبع لقياس جمهور التطبيق وتخصيص الإعلانات.",
        "accept_all": "قبول الكل", "reject_all": "رفض الكل", "customize": "تخصيص", "save": "حفظ", "close": "المتابعة دون قبول",
        "floating_button": "إدارة ملفات تعريف الارتباط", "preferences_title": "تفضيلاتك", "preferences_intro": "اختر.",
        "kicker": "قبل أن تبدأ", "policy_url": NSNull(),
        "purposes": [
            "necessary": ["name": "ضرورية", "description": "تشغيل التطبيق والاحتفاظ باختيارك."],
            "analytics": ["name": "قياس الجمهور", "description": "فهم كيفية استخدام التطبيق."],
            "advertising": ["name": "الإعلانات", "description": "عرض إعلانات تناسب اهتماماتك."],
        ],
    ]

    static let de: [String: Any] = [
        "title": "Ihre Daten, Ihre Wahl",
        "message": "Atelier Mona und seine Partner verwenden Tracker, um die Nutzung der App zu messen und Werbung zu personalisieren.",
        "accept_all": "Alle akzeptieren", "reject_all": "Alle ablehnen", "customize": "Anpassen", "save": "Speichern",
        "close": "Weiter ohne Zustimmung", "floating_button": "Cookies verwalten", "preferences_title": "Ihre Einstellungen",
        "preferences_intro": "Sie entscheiden.", "kicker": "Bevor es losgeht", "policy_url": NSNull(),
        "purposes": [
            "necessary": ["name": "Notwendig", "description": "Die App betreiben und Ihre Wahl speichern."],
            "analytics": ["name": "Reichweitenmessung", "description": "Verstehen, wie die App genutzt wird."],
            "advertising": ["name": "Werbung", "description": "Werbung anzeigen, die zu Ihren Interessen passt."],
        ],
    ]

    /// The sheet's model from the kit's golden configuration, through the engine (as an app gets it).
    static func model(for c: SheetSnapshotTests.Case) throws -> SheetModel {
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: kit(c.tcf ? "bodies/config-tcf.json" : "bodies/config.json"))) as! [String: Any]
        var cfg = root["config"] as! [String: Any]
        var ui = cfg["ui"] as! [String: Any]
        var texts = ui["texts"] as! [String: Any]
        var fr = texts["fr"] as! [String: Any]
        fr["kicker"] = "Avant de commencer"
        texts["fr"] = fr
        texts["de"] = de
        texts["ar"] = ar
        ui["texts"] = texts
        ui["languages"] = ["fr", "de", "ar"]
        ui["rtl"] = ["ar"]
        var hashes = ui["text_hashes"] as! [String: Any]
        hashes["de"] = String(repeating: "d", count: 64)
        hashes["ar"] = String(repeating: "a", count: 64)
        ui["text_hashes"] = hashes
        ui["logo_url"] = SheetSnapshotTests.iconURL
        if var hero = ui["hero"] as? [String: Any] {
            hero["poster"] = [["url": SheetSnapshotTests.heroURL, "type": "image/jpeg", "w": 960]]
            ui["hero"] = hero
        }
        c.edit(&ui)
        cfg["ui"] = ui
        root["config"] = cfg
        let net = FixedNet(config: try JSONSerialization.data(withJSONObject: root))
        let host = Capture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmp-snap-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let choice = Memory()
        let q = DispatchQueue(label: "snap")
        let env = CMPEnvironment(
            scheduler: CMPQueueScheduler(queue: q), http: net, choice: choice, iab: MemoryKeys(), kept: MemoryKeys(),
            files: CMPFiles(directory: dir),
            device: CMPDevice(bundleId: "fr.ateliermona.app", appVersion: "2.3.0", shortSide: 393, languages: [c.lang]))
        let e = CMPEngine(env: env, options: .init(appId: "ATMONA02", base: URL(string: "https://cdn.scruter.net")!, automatic: true), queue: q)
        e.host = host
        q.sync { e.start() }
        if c.layer == .preferences {
            let first = try XCTUnwrap(host.shown.first)
            q.sync { e.decide(SheetDecision(action: .custom, granted: ["analytics"], source: .banner), model: first) }
            q.sync { e.showPreferences(anchor: nil) }
        }
        return try XCTUnwrap(host.shown.last)
    }

    static func kit(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("protocol/cmp/" + path)
    }
}

final class FixedNet: CMPHTTP {
    let config: Data
    init(config: Data) { self.config = config }
    func send(_ request: CMPRequest, completion: @escaping (CMPResponse?) -> Void) {
        let path = request.url.path
        if path.hasSuffix("/m/v1/cmp") { return completion(CMPResponse(status: 200, headers: [:], body: config)) }
        // The IAB TCF: the kit's vendor subset and IAB's translations (sdk/protocol/cmp/tcf).
        var file: String?
        if path.hasPrefix("/cmp/ATMONA02/vendors-") { file = "tcf/vendors-186.json" }
        if path.hasPrefix("/cmp/tcf/186/") { file = "tcf/186-" + request.url.deletingPathExtension().lastPathComponent + ".json" }
        if let f = file, let d = try? Data(contentsOf: Fixtures.kit(f)) {
            return completion(CMPResponse(status: 200, headers: [:], body: d))
        }
        completion(CMPResponse(status: file == nil ? 202 : 404, headers: [:], body: Data("{}".utf8)))
    }
}

final class Capture: CMPHost {
    var shown: [SheetModel] = []
    func show(_ model: SheetModel, anchor: AnyObject?) { shown.append(model) }
    func dismiss() {}
    func deliver(_ block: @escaping () -> Void) {}
    func prefetch(_ urls: [String]) {}
}

final class MemoryKeys: CMPKeyStore {
    var values: [String: Any] = [:]
    func read(_ key: String) -> Any? { values[key] }
    func write(_ v: [String: Any?]) { for (k, x) in v { values[k] = x } }
}

final class Memory: CMPChoiceStore {
    var value: String?
    func read() -> String? { value }
    func write(_ v: String?) { value = v }
}
