import XCTest

/// The UIKit example app (manual presentation after an onboarding) against the local ingest.
final class CMPUIKitUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        post("/_stub/mode", ["config": "base", "consent": "ok"])
    }

    private func post(_ path: String, _ body: [String: Any]) {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:8765" + path)!)
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: r) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }

    func testManualPresentationAfterTheOnboarding() throws {
        let a = XCUIApplication()
        a.launchArguments = ["-cmp-endpoint", "http://127.0.0.1:8765", "-cmp-fresh-install", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        a.launch()
        XCTAssertTrue(a.buttons["onboarding-continue"].waitForExistence(timeout: 10))
        XCTAssertFalse(a.buttons["scruter-cmp-accept-all"].waitForExistence(timeout: 3), "manual: nothing before showIfNeeded")
        a.buttons["onboarding-continue"].tap()
        let accept = a.buttons["scruter-cmp-accept-all"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        XCTAssertEqual(accept.label, "Alle akzeptieren", "the device's language, fetched from the version's texts")
        if #available(iOS 17.0, *) {
            try Audit.run(a) { issue in !(issue.element?.identifier.hasPrefix("scruter-cmp") ?? false) }
        }
        a.buttons["scruter-cmp-reject-all"].tap()
        XCTAssertFalse(accept.waitForExistence(timeout: 2))
        a.cells["privacy-choices"].tap()
        XCTAssertTrue(a.buttons["scruter-cmp-preferences-close"].waitForExistence(timeout: 5))
        XCTAssertEqual(a.switches["scruter-cmp-switch-analytics"].value as? String, "0")
        a.buttons["scruter-cmp-preferences-close"].tap()
        XCTAssertFalse(a.buttons["scruter-cmp-preferences-close"].waitForExistence(timeout: 2))
    }
}
