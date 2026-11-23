import XCTest

/// The IAB TCF in the SwiftUI example app (docs/CMP-MOBILE.md §6) against the local ingest in mode `tcf` (the kit's
/// `config-tcf.json` and GVL 186 vendors): the first launch with the IAB text, accept all, reject all, an objection to
/// a partner's legitimate interest, the keys a TCF vendor reads before the app hears of the choice, a re-ask after a GVL
/// change, `debugReset()`, and the accessibility audit of every TCF layer.
final class TCFUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        Stub.post("/_stub/mode", ["config": "tcf", "consent": "ok"])
        Stub.post("/_stub/clear", [:])
        addUIInterruptionMonitor(withDescription: "App Tracking Transparency") { alert in
            let refuse = alert.buttons.element(boundBy: 0)
            guard refuse.exists else { return false }
            refuse.tap()
            return true
        }
    }

    override func tearDown() {
        Stub.post("/_stub/mode", ["config": "base"])
    }

    private func app(fresh: Bool, extra: [String] = []) -> XCUIApplication {
        let a = XCUIApplication()
        a.launchArguments = ["-cmp-endpoint", CMPUITests.stub, "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"] + extra
        if fresh { a.launchArguments.append("-cmp-fresh-install") }
        a.launch()
        return a
    }

    private func button(_ a: XCUIApplication, _ id: String) -> XCUIElement { a.buttons["scruter-cmp-" + id] }

    private func label(_ a: XCUIApplication, _ id: String) -> XCUIElement { a.staticTexts.matching(identifier: "partner-" + id).firstMatch }

    private func audit(_ a: XCUIApplication, _ name: String) throws {
        guard #available(iOS 17.0, *) else { return }
        let sheet = a.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'scruter-cmp-'")).firstMatch
        let area = sheet.exists ? sheet.frame : a.frame
        // The row of buttons: a long layer scrolls under it, and the audit measures a row cut by the scroll view's edge
        // against what is beside it (a false contrast failure); those rows are measured once scrolled into view.
        let bar = a.buttons["scruter-cmp-reject-all"].exists ? a.buttons["scruter-cmp-reject-all"].frame.minY - 16 : .greatestFiniteMagnitude
        try Audit.run(a) { issue in
            guard let e = issue.element else { return issue.auditType == .elementDetection }
            if issue.auditType == .contrast && e.frame.maxY > bar { return true }
            // A text the screen's edge cuts is measured as clipped (« Dynamic Type font sizes are partially
            // unsupported ») whatever its font does: a slow runner left the vendor page mid-scroll on 2026-11-23, and
            // the same row passed once in view. A text wholly on screen is still audited.
            if issue.auditType == .dynamicType && !a.frame.contains(e.frame) { return true }
            let ours = e.identifier.hasPrefix("scruter-cmp") || area.contains(CGPoint(x: e.frame.midX, y: e.frame.midY))
            if ours { print("[a11y] \(name): \(issue.compactDescription) — \(e.identifier) \(e.label)") }
            return !ours
        }
    }

    private func waitLabel(_ e: XCUIElement, _ value: String, _ why: String) {
        let ok = expectation(for: NSPredicate(format: "label == %@", value), evaluatedWith: e)
        wait(for: [ok], timeout: 10)
        XCTAssertEqual(e.label, value, why)
    }

    func testFirstLaunchAcceptAllWritesTheKeys() throws {
        let a = app(fresh: true)
        XCTAssertTrue(button(a, "accept-all").waitForExistence(timeout: 20), "the sheet shows at the first launch")
        let text = a.staticTexts.matching(identifier: "scruter-cmp-tcf-text").firstMatch
        XCTAssertTrue(text.exists, "the IAB text in the message's place")
        // The TCF's ten and Google's six other partners (golden configuration).
        XCTAssertTrue(text.label.contains("16 partenaires"), text.label)
        try audit(a, "TCF first layer")
        button(a, "accept-all").tapSettled()
        let consent = try XCTUnwrap(Stub.wait("cmp-consent"))
        XCTAssertEqual(consent["c"] as? String, "accept_all")
        XCTAssertEqual(consent["gv"] as? Int, 186)
        let tc = try XCTUnwrap(consent["tc"] as? String)
        XCTAssertTrue(tc.hasPrefix("C"), tc)
        // What Google Mobile Ads reads, already there when the app hears of the choice.
        waitLabel(label(a, "tcf"), "528|1|10110000100|tc", "the IAB keys after « Tout accepter »")
    }

    func testRejectAll() throws {
        let a = app(fresh: true)
        XCTAssertTrue(button(a, "reject-all").waitForExistence(timeout: 20))
        button(a, "reject-all").tapSettled()
        let consent = try XCTUnwrap(Stub.wait("cmp-consent"))
        XCTAssertEqual(consent["c"] as? String, "reject_all")
        XCTAssertNotNil(consent["tc"])
        waitLabel(label(a, "tcf"), "528|1|00000000000|tc", "no consent signalled after « Tout refuser »")
        XCTAssertEqual(label(a, "tcf-vli").label, "-", "no legitimate interest either")
    }

    func testAnObjectionToAPartnersLegitimateInterest() throws {
        let a = app(fresh: true)
        XCTAssertTrue(button(a, "customize").waitForExistence(timeout: 20))
        // « Voir nos 16 partenaires », a link of the first layer's small print.
        let partners = a.links.matching(NSPredicate(format: "label CONTAINS 'partenaires'")).firstMatch
        if partners.exists {
            partners.tapSettled()
        } else {
            button(a, "customize").tapSettled()
            button(a, "next").tapSettled()
            button(a, "next").tapSettled()
        }
        XCTAssertTrue(a.staticTexts.matching(identifier: "scruter-cmp-partners").firstMatch.waitForExistence(timeout: 5))
        // The search narrows the list to the partner (the audit then sees every row whole, none cut by the scroll view).
        let search = a.textFields["scruter-cmp-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tapSettled()
        search.typeText("Trade\n")
        try audit(a, "TCF partners")
        let ttd = button(a, "vendor-21")
        XCTAssertTrue(ttd.waitForExistence(timeout: 3))
        ttd.tapSettled()
        let li = a.switches["scruter-cmp-detail-li"]
        XCTAssertTrue(li.waitForExistence(timeout: 3))
        XCTAssertEqual(li.value as? String, "1", "legitimate interest kept until the visitor objects")
        try audit(a, "TCF vendor")
        li.settled().coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(li.value as? String, "0")
        button(a, "tcf-back").tapSettled()
        button(a, "save").tapSettled()
        // « Enregistrer » with no banner purpose granted is a refusal (the module derives the action from the switches);
        // the TCF layers' choice goes with it.
        let consent = try XCTUnwrap(Stub.wait("cmp-consent"))
        XCTAssertNotNil(consent["tc"])
        // Vendor 21 objected to: its bit (index 20) is 0 while the other vendors on legitimate interest keep theirs.
        let vli = label(a, "tcf-vli")
        let ok = expectation(for: NSPredicate(format: "label.length > 21"), evaluatedWith: vli)
        wait(for: [ok], timeout: 10)
        let bits = Array(vli.label)
        XCTAssertEqual(bits[20], "0", vli.label)
        XCTAssertEqual(bits[31], "1", "Xandr (32) keeps its legitimate interest: " + vli.label)
    }

    func testAReaskAfterAGVLChangeThenDebugReset() throws {
        var a = app(fresh: true)
        XCTAssertTrue(button(a, "accept-all").waitForExistence(timeout: 20))
        button(a, "accept-all").tapSettled()
        XCTAssertNotNil(Stub.wait("cmp-consent"))
        a.terminate()
        // GVL 187: the vendors changed what advertising rests on; the server bumped its revision.
        Stub.post("/_stub/mode", ["config": "tcf-gvl"])
        Stub.post("/_stub/clear", [:])
        a = app(fresh: false, extra: ["-cmp-drop-config"])
        XCTAssertTrue(button(a, "accept-all").waitForExistence(timeout: 20), "asked again after the GVL change")
        button(a, "accept-all").tapSettled()
        // The new decision's proof (the first launch's may arrive again, if the app was killed before its answer).
        var consent: [String: Any]?
        let end = Date().addingTimeInterval(15)
        repeat {
            consent = Stub.wait("cmp-consent", timeout: 1).flatMap { ($0["r"] as? Int) == 4 ? $0 : nil }
        } while consent == nil && Date() < end
        let proof = try XCTUnwrap(consent)
        XCTAssertEqual(proof["gv"] as? Int, 187)
        waitLabel(label(a, "tcf"), "528|1|10110000100|tc", "the new decision's keys")
        // debugReset(): the choice and its keys go; the CMP's header stays for the configuration; the sheet shows again.
        a.tabBars.buttons.element(boundBy: 1).tapSettled()
        a.buttons["debug-reset"].tapSettled()
        XCTAssertTrue(button(a, "accept-all").waitForExistence(timeout: 10))
        try audit(a, "TCF first layer after debugReset")
        button(a, "customize").tapSettled()
        XCTAssertTrue(a.switches["scruter-cmp-iab-1"].waitForExistence(timeout: 5) || a.switches["scruter-cmp-switch-analytics"].exists)
        try audit(a, "TCF step")
        button(a, "reject-all").tapSettled()
        a.tabBars.buttons.element(boundBy: 0).tapSettled()
        waitLabel(label(a, "tcf"), "528|1|00000000000|tc", "a new decision after the reset")
    }
}
