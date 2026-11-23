import XCTest

/// The SwiftUI example app against a local ingest (ios/scripts/cmp_stub_ingest.py on port 8765): first launch, offline
/// first launch, decision, the steps, a re-ask after a new configuration, withdrawal, the process killed during the
/// decision, and the accessibility audit of each layer (docs/CMP-MOBILE.md §9.2).
final class CMPUITests: XCTestCase {
    static let stub = "http://127.0.0.1:8765"

    override func setUp() {
        continueAfterFailure = false
        Stub.post("/_stub/mode", ["config": "base", "consent": "ok"])
        Stub.post("/_stub/clear", [:])
        // Apple's tracking prompt follows an advertising consent (§3.9): refused where a test does not look at it.
        addUIInterruptionMonitor(withDescription: "App Tracking Transparency") { alert in
            let refuse = alert.buttons.element(boundBy: 0)
            guard refuse.exists else { return false }
            refuse.tap()
            return true
        }
    }

    /// Apple's tracking prompt, drawn by SpringBoard.
    private var trackingAlert: XCUIElement { XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch }

    private func app(fresh: Bool, endpoint: String = CMPUITests.stub, extra: [String] = []) -> XCUIApplication {
        let a = XCUIApplication()
        a.launchArguments = ["-cmp-endpoint", endpoint, "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"] + extra
        if fresh { a.launchArguments.append("-cmp-fresh-install") }
        a.launch()
        return a
    }

    private func button(_ a: XCUIApplication, _ id: String) -> XCUIElement { a.buttons["scruter-cmp-" + id] }

    /// `performAccessibilityAudit` on the screen: the sheet's issues fail the test (the example app's own screens are
    /// not the module's).
    private func audit(_ a: XCUIApplication, _ name: String) throws {
        guard #available(iOS 17.0, *) else { return }
        let sheet = a.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'scruter-cmp-'")).firstMatch
        let area = sheet.exists ? sheet.frame : a.frame
        try Audit.run(a) { issue in
            // The app behind the sheet is hidden from VoiceOver on purpose (the sheet is modal, §3.12): its visible text
            // is reported without an element.
            guard let e = issue.element else { return issue.auditType == .elementDetection }
            let ours = e.identifier.hasPrefix("scruter-cmp") || area.contains(CGPoint(x: e.frame.midX, y: e.frame.midY))
            if ours { print("[a11y] \(name): \(issue.compactDescription) — \(e.identifier) \(e.label)") }
            return !ours
        }
    }

    func testFirstLaunchAndDecision() throws {
        let a = app(fresh: true)
        XCTAssertTrue(button(a, "accept-all").waitForExistence(timeout: 15), "the sheet shows at the first launch")
        XCTAssertTrue(button(a, "reject-all").exists)
        XCTAssertTrue(button(a, "customize").exists)
        XCTAssertTrue(button(a, "close").exists, "« Continuer sans accepter » in the band")
        XCTAssertEqual(button(a, "accept-all").frame.width, button(a, "reject-all").frame.width, accuracy: 1, "equal buttons")
        XCTAssertEqual(button(a, "accept-all").frame.height, button(a, "reject-all").frame.height, accuracy: 1)
        try audit(a, "first layer")
        // No gesture closes it.
        let body = a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        body.press(forDuration: 0.1, thenDragTo: a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(button(a, "accept-all").exists)
        button(a, "accept-all").tapSettled()
        let saved = a.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'scruter-cmp-saved' OR label CONTAINS 'enregistr'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "the confirmation")
        // ATT after the CMP, because advertising was granted.
        XCTAssertTrue(trackingAlert.waitForExistence(timeout: 10), "Apple's tracking prompt after an advertising consent")
        trackingAlert.buttons.element(boundBy: 1).tap()
        let att = a.staticTexts.matching(identifier: "partner-att").firstMatch
        wait(for: [expectation(for: NSPredicate(format: "label == 'authorized'"), evaluatedWith: att)], timeout: 15)
        XCTAssertTrue(a.staticTexts.matching(identifier: "partner-analytics").firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(a.staticTexts.matching(identifier: "partner-analytics").firstMatch.label, "on")
        XCTAssertEqual(a.staticTexts.matching(identifier: "partner-ads").firstMatch.label, "personalised")
        let consent = try XCTUnwrap(Stub.wait("cmp-consent"))
        XCTAssertEqual(consent["c"] as? String, "accept_all")
        XCTAssertEqual(consent["o"] as? String, "banner")
        XCTAssertEqual(consent["dbg"] as? Int, 1, "a simulator build is a debug build")
        let hit = try XCTUnwrap(Stub.wait("cmp-hit"))
        XCTAssertEqual(hit["d"] as? Int, 1)
        XCTAssertNotNil(Stub.wait("cmp-sdks"), "the detected SDKs are reported")
    }

    func testCustomiseStepByStep() throws {
        let a = app(fresh: true)
        XCTAssertTrue(button(a, "customize").waitForExistence(timeout: 15))
        button(a, "customize").tapSettled()
        XCTAssertTrue(a.staticTexts["Étape 1 sur 2"].waitForExistence(timeout: 3))
        let analytics = a.switches["scruter-cmp-switch-analytics"]
        XCTAssertEqual(analytics.value as? String, "0", "nothing is pre-ticked")
        try audit(a, "step 1")
        // The switch itself, at the row's trailing end.
        analytics.settled().coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(analytics.value as? String, "1")
        button(a, "next").tapSettled()
        XCTAssertTrue(a.staticTexts["Étape 2 sur 2"].waitForExistence(timeout: 3))
        XCTAssertTrue(button(a, "save").exists, "« Enregistrer » on the last step")
        button(a, "back").tapSettled()
        XCTAssertTrue(a.staticTexts["Étape 1 sur 2"].waitForExistence(timeout: 3))
        button(a, "next").tapSettled()
        button(a, "save").tapSettled()
        let consent = try XCTUnwrap(Stub.wait("cmp-consent"))
        XCTAssertEqual(consent["c"] as? String, "custom")
        XCTAssertEqual(consent["g"] as? [String], ["analytics"])
        XCTAssertEqual(consent["n"] as? [String], ["advertising"])
        XCTAssertFalse(trackingAlert.waitForExistence(timeout: 3), "no tracking prompt without an advertising consent")
    }

    func testContinueWithoutAccepting() throws {
        let a = app(fresh: true)
        XCTAssertTrue(button(a, "close").waitForExistence(timeout: 15))
        button(a, "close").tapSettled()
        let consent = try XCTUnwrap(Stub.wait("cmp-consent"))
        XCTAssertEqual(consent["c"] as? String, "close")
        XCTAssertEqual(consent["g"] as? [String], [])
    }

    func testOfflineFirstLaunch() throws {
        var a = app(fresh: true, endpoint: "http://127.0.0.1:9")
        XCTAssertFalse(button(a, "accept-all").waitForExistence(timeout: 5), "no configuration: no sheet")
        XCTAssertTrue(a.staticTexts.matching(identifier: "partner-analytics").firstMatch.exists)
        XCTAssertEqual(a.staticTexts.matching(identifier: "partner-analytics").firstMatch.label, "off", "every optional purpose denied")
        a.terminate()
        a = app(fresh: false)
        XCTAssertTrue(button(a, "accept-all").waitForExistence(timeout: 15), "asked once the network answers")
    }

    func testReaskAfterANewConfiguration() throws {
        var a = app(fresh: true)
        XCTAssertTrue(button(a, "accept-all").waitForExistence(timeout: 15))
        button(a, "accept-all").tapSettled()
        XCTAssertNotNil(Stub.wait("cmp-consent"))
        a.terminate()
        Stub.post("/_stub/mode", ["config": "reask"])
        Stub.post("/_stub/clear", [:])
        a = app(fresh: false, extra: ["-cmp-drop-config"])
        XCTAssertTrue(button(a, "reject-all").waitForExistence(timeout: 15), "advertising changed: asked again")
        button(a, "reject-all").tapSettled()
        let consent = try XCTUnwrap(Stub.wait("cmp-consent"))
        XCTAssertEqual(consent["r"] as? Int, 4)
        XCTAssertEqual(consent["c"] as? String, "withdraw", "everything refused after a consent")
    }

    func testWithdrawalFromTheSettings() throws {
        let a = app(fresh: true)
        XCTAssertTrue(button(a, "accept-all").waitForExistence(timeout: 15))
        button(a, "accept-all").tapSettled()
        XCTAssertNotNil(Stub.wait("cmp-consent"))
        Stub.post("/_stub/clear", [:])
        a.tabBars.buttons.element(boundBy: 1).tapSettled()
        a.buttons["privacy-choices"].tapSettled()
        XCTAssertTrue(a.otherElements["scruter-cmp-preferences"].waitForExistence(timeout: 5) || button(a, "reject-all").waitForExistence(timeout: 5))
        XCTAssertEqual(a.switches["scruter-cmp-switch-analytics"].value as? String, "1")
        XCTAssertTrue(a.staticTexts["Toujours actif"].exists)
        try audit(a, "preferences")
        // « Tout refuser » after a consent: a withdrawal.
        button(a, "reject-all").tapSettled()
        let consent = try XCTUnwrap(Stub.wait("cmp-consent"))
        XCTAssertEqual(consent["c"] as? String, "withdraw")
        XCTAssertEqual(consent["o"] as? String, "preferences")
        a.tabBars.buttons.element(boundBy: 0).tapSettled()
        XCTAssertEqual(a.staticTexts.matching(identifier: "partner-analytics").firstMatch.label, "off")
    }

    func testProcessKilledDuringTheDecision() throws {
        Stub.post("/_stub/mode", ["consent": "fail"])
        var a = app(fresh: true)
        XCTAssertTrue(button(a, "accept-all").waitForExistence(timeout: 15))
        button(a, "accept-all").tapSettled()
        a.terminate()
        XCTAssertNil(Stub.wait("cmp-consent", timeout: 1), "the proof did not arrive")
        Stub.post("/_stub/mode", ["consent": "ok"])
        a = app(fresh: false)
        XCTAssertFalse(button(a, "accept-all").waitForExistence(timeout: 3), "the choice was written before the sheet closed")
        let consent = try XCTUnwrap(Stub.wait("cmp-consent", timeout: 15), "sent again at the next launch")
        XCTAssertEqual(consent["c"] as? String, "accept_all")
    }
}

/// The local ingest's control API.
enum Stub {
    static func request(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> Data? {
        var r = URLRequest(url: URL(string: CMPUITests.stub + path)!)
        r.httpMethod = method
        if let b = body { r.httpBody = try? JSONSerialization.data(withJSONObject: b) }
        let done = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: r) { d, _, _ in
            out = d
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return out
    }

    static func post(_ path: String, _ body: [String: Any]) { _ = request("POST", path, body) }

    /// The last beacon of `schema` received, waiting up to `timeout` seconds.
    static func wait(_ schema: String, timeout: TimeInterval = 10) -> [String: Any]? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let d = request("GET", "/_stub/received"), let list = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]],
                let last = list.last(where: { $0["schema"] as? String == schema })?["body"] as? [String: Any]
            {
                return last
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < end
        return nil
    }
}

extension XCUIElement {
    /// The element once it stands still: the sheet slides in, and so do its layers, and a tap placed mid-slide lands
    /// beside the control (the first layer's « Tout accepter » on a CI runner, 2026-11-22).
    @discardableResult
    func settled(timeout: TimeInterval = 5) -> XCUIElement {
        guard waitForExistence(timeout: timeout) else { return self }
        let end = Date().addingTimeInterval(timeout)
        var last = frame
        repeat {
            Thread.sleep(forTimeInterval: 0.3)
            let now = frame
            if now == last, isHittable { break }
            last = now
        } while Date() < end
        return self
    }

    func tapSettled() { settled().tap() }
}
