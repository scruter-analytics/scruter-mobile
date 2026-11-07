import Foundation
import XCTest

@testable import ScruterAnalytics

final class TeamTests: XCTestCase {
    static func teamServer(_ h: Harness, status: Int = 201) {
        h.http.respond = { req in
            let p = req.url.path
            if p.hasSuffix("/m/v1/config") {
                return HTTPResponse(status: 200, headers: [:], body: Data(#"{"v":1,"on":1,"e":"t1","tp":1,"ttl":3600}"#.utf8))
            }
            if p.hasSuffix("/m/v1/team/register") {
                return HTTPResponse(
                    status: status, headers: [:],
                    body: Data(#"{"phone_id":"p1","device_token":"scr_tp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","name":"iPhone 15 Pro Max"}"#.utf8))
            }
            if p.hasSuffix("/m/v1/team/config") {
                return HTTPResponse(status: 200, headers: [:], body: Data(#"{"phone_id":"p1","captured":["Home"],"retake":["Cart"],"max_bytes":2000000,"max_height":10000,"ttl":600}"#.utf8))
            }
            if p.hasSuffix("/m/v1/team/screens") { return HTTPResponse(status: 202, headers: [:], body: Data(#"{"id":"i1"}"#.utf8)) }
            return HTTPResponse(status: 202, headers: [:], body: Data("{}".utf8))
        }
    }

    /// A link can come from anyone: a phone only becomes a team phone when the person holding it says yes.
    func testTeamLinkAsksFirstAndRefusingRegistersNothing() {
        let h = Harness()
        h.teamAnswer = false
        Self.teamServer(h)
        let e = h.boot()
        e.enterForeground()
        let url = URL(string: "scruter-atmona02://team?t=scr_qr_" + String(repeating: "B", count: 32))!
        XCTAssertTrue(e.handle(url: url), "still Scruter's own link")
        h.advance(seconds: 1)
        XCTAssertNil(h.http.requests.first { $0.url.path.hasSuffix("register") })
        XCTAssertFalse(e.team.isActive)
    }

    func testTheTeamQuestionNamesTheAppInTheLanguagesOfTheConsole() {
        XCTAssertTrue(TeamPrompt.text(language: "fr-FR", app: "Atelier Mona").title.contains("Atelier Mona"))
        XCTAssertEqual(TeamPrompt.text(language: "de-AT", app: "A").add, "Hinzufügen")
        XCTAssertEqual(TeamPrompt.text(language: "ja-JP", app: "A").add, "Add")
    }

    /// The same table as the server's and Android's tests (docs/MOBILE.md §3.13).
    func testLinksLoseTheirPersonalSegments() {
        for (from, to) in [
            ("https://a.fr/promo/noel", "https://a.fr/promo/noel"),
            ("https://a.fr/u/camille@x.fr/edit", "https://a.fr/u/:id/edit"),
            ("https://a.fr/orders/123456?utm_source=mail&token=abc", "https://a.fr/orders/:id?utm_source=mail"),
            ("https://a.fr/c/42", "https://a.fr/c/:id"),
            ("https://a.fr/CMD-2026-48213/x", "https://a.fr/:id/x"),
            ("https://a.fr/t/1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9", "https://a.fr/t/:id"),
            ("https://a.fr/r/9fK2mQ7xLp3Tz8Wq", "https://a.fr/r/:id"),
            ("https://a.fr/soldes-hiver-2026", "https://a.fr/soldes-hiver-2026"),
            ("https://a.fr/iphone-15-pro", "https://a.fr/iphone-15-pro"),
        ] {
            XCTAssertEqual(Links.sanitize(URL(string: from)!), to, from)
        }
    }

    func testQRCodeRegistrationAndCaptureRequests() throws {
        let h = Harness()
        h.device.buildKind = "testflight"
        Self.teamServer(h)
        let e = h.boot()
        var asked = [String]()
        e.onCapture = { asked.append($0) }
        e.enterForeground()
        let url = URL(string: "scruter-atmona02://team?t=scr_qr_" + String(repeating: "B", count: 32))!
        XCTAssertTrue(e.handle(url: url))
        h.advance(seconds: 0)
        let reg = try XCTUnwrap(h.http.requests.first { $0.url.path.hasSuffix("register") })
        XCTAssertEqual(reg.url.absoluteString, "https://api.scruter.net/m/v1/team/register")
        let body = try XCTUnwrap(reg.body.flatMap(JSON.parse))
        XCTAssertEqual(body["build_kind"], "testflight")
        Harness.export(body, name: "team-register-qr")
        XCTAssertTrue(e.team.isActive)
        let cfg = try XCTUnwrap(h.http.requests.first { $0.url.path.hasSuffix("team/config") })
        XCTAssertEqual(cfg.headers["Authorization"], "Bearer scr_tp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(cfg.url.query, "av=2.3.0&p=ios&f=phone")
        e.screen("Home")
        e.screen("Cart")
        e.screen("Shop")
        XCTAssertEqual(asked, ["Cart", "Shop"], "already captured: Home; retake asked: Cart")
        // The next session of the phone is flagged tm = 1 (never counted).
        e.enterBackground()
        h.advance(seconds: 31 * 60)
        e.enterForeground()
        XCTAssertEqual(e.current?.dims["tm"], 1)
        // Upload.
        var ok = false
        let meta = Team.meta(screen: "Shop", device: h.device, width: 786, height: 4280, scale: 2, takenAt: Date())
        let tree: JSON = ["v": 1, "nodes": [["s": "#add_to_cart", "i": 0, "k": "button", "x": 24, "y": 1180, "w": 345, "h": 48, "l": "Add to cart", "m": 0], ["s": "UITextField", "i": 0, "k": "input", "x": 24, "y": 1300, "w": 345, "h": 44, "m": 1]]]
        Harness.export(meta, name: "team-meta")
        Harness.export(tree, name: "team-tree")
        e.team.upload(screen: "Shop", meta: meta, jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), tree: tree) { ok = $0 }
        XCTAssertTrue(ok)
        let up = try XCTUnwrap(h.http.requests.last)
        XCTAssertTrue(up.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=scruter-") ?? false)
        let text = String(decoding: up.body!, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"meta\""))
        XCTAssertTrue(text.contains("name=\"image\"; filename=\"screen.jpg\"\r\nContent-Type: image/jpeg"))
        XCTAssertTrue(text.contains("name=\"tree\""))
        XCTAssertFalse(e.team.wants(screen: "Shop"), "once per screen and run")
    }

    func testDebugKeyOnlyInADebugBuild() throws {
        let key = "scr_dbg_" + String(repeating: "k", count: 43)
        let release = Harness()
        Self.teamServer(release)
        release.options.debugKey = key
        release.boot()
        XCTAssertNil(release.http.requests.first { $0.url.path.hasSuffix("register") }, "a release build never uses the key")

        let debug = Harness()
        Self.teamServer(debug)
        debug.device.isDebugBuild = true
        debug.device.buildKind = "debug"
        debug.options.debugKey = key
        let e = debug.boot()
        let reg = try XCTUnwrap(debug.http.requests.first { $0.url.path.hasSuffix("register") })
        let body = try XCTUnwrap(reg.body.flatMap(JSON.parse))
        XCTAssertEqual(body["debug_key"]?.stringValue, key)
        XCTAssertEqual(body["build_kind"], "debug")
        Harness.export(body, name: "team-register-debug")
        XCTAssertTrue(e.team.isActive)
    }

    func testRevokedPhoneLeavesTeamMode() {
        let h = Harness()
        Self.teamServer(h)
        h.device.isDebugBuild = true
        h.device.buildKind = "debug"
        h.options.debugKey = "scr_dbg_" + String(repeating: "k", count: 43)
        let e = h.boot()
        XCTAssertTrue(e.team.isActive)
        h.http.respond = { _ in HTTPResponse(status: 401, headers: [:], body: Data()) }
        e.team.fetchConfig()
        XCTAssertFalse(e.team.isActive)
        XCTAssertNil(FileSecretStore(store: FileStore(directory: h.dir)).get(Team.tokenKey))
    }
}
