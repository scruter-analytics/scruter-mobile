import Foundation
import XCTest

@_spi(ScruterBridge) @testable import ScruterAnalytics

final class AnalysedTests: XCTestCase {
    static func fullCollection(_ h: Harness) {
        h.http.respond = { req in
            if req.url.path.hasSuffix("config") {
                return HTTPResponse(
                    status: 200, headers: [:],
                    body: Data(#"{"v":1,"on":1,"e":"etag2","tz":"Europe/Paris","aa":100,"cr":1,"xs":[],"tp":1,"ttl":3600}"#.utf8))
            }
            return HTTPResponse(status: 202, headers: [:], body: Data("{}".utf8))
        }
    }

    func testAnalysedScreenView() throws {
        let h = Harness()
        Self.fullCollection(h)
        let e = h.boot()
        e.enterForeground()
        XCTAssertTrue(e.current!.analysed)
        e.screen("Product page")
        e.setViewport(width: 393, height: 852)
        h.advance(seconds: 1)
        e.scrolled(top: 0, bottom: 0.4, contentHeight: 2140, viewport: (393, 852), user: false)
        h.advance(seconds: 2)
        e.scrolled(top: 0.4, bottom: 0.8, contentHeight: 2140, viewport: (393, 852), user: true)
        h.advance(seconds: 1)
        e.tap(selector: "#gallery/Image", index: 0, kind: "image", x: 48, y: 52, point: (100, 300), interactive: true)
        // A dead tap: nothing happens within a second.
        let token = e.tap(selector: "UILabel", index: 2, kind: "text", x: 10, y: 90, point: (50, 500), interactive: false)
        XCTAssertGreaterThan(token, 0)
        h.advance(seconds: 1)
        e.resolveTap(token, dead: true)
        // A rage burst: three taps within a second inside 24 points.
        for i in 0..<4 {
            e.tap(selector: "#add_to_cart", index: 0, kind: "button", x: 50, y: 50, point: (200 + Double(i), 700), interactive: true)
            h.advance(seconds: 0.2)
        }
        // A form: two fields, one changed, an error after a tap elsewhere (a refused attempt), then sent.
        e.formField(form: "Delivery", key: "postalCode", type: "text", position: 0)
        e.formField(form: "Delivery", key: "city", type: "text", position: 1)
        e.formFocus(form: "Delivery", key: "postalCode")
        h.advance(seconds: 4)
        e.formChanged(form: "Delivery", key: "postalCode")
        e.formBlur(form: "Delivery", key: "postalCode")
        e.tap(selector: "#submit", index: 0, kind: "button", x: 50, y: 50, point: (300, 800), interactive: true)
        e.fieldError(key: "postalCode", kind: .format)
        h.advance(seconds: 2)
        e.formChanged(form: "Delivery", key: "postalCode")
        e.formSent("Delivery")
        e.screen("Cart")
        e.flush()

        let batch = try XCTUnwrap(h.http.batches.last)
        let views = try XCTUnwrap(batch["x"]?.arrayValue)
        let fiche = try XCTUnwrap(views.last { $0["n"] == "Product page" })
        XCTAssertEqual(fiche["vw"], 393)
        XCTAssertEqual(fiche["ch"], 2140)
        XCTAssertEqual(fiche["sd"], 80)
        XCTAssertEqual(fiche["ia"], 1)
        XCTAssertEqual(fiche["cn"], 7)
        XCTAssertEqual(fiche["cd"], 1)
        XCTAssertEqual(fiche["cr"], 1)
        let taps = views.filter { $0["n"] == "Product page" }.flatMap { $0["c"]?.arrayValue ?? [] }
        XCTAssertEqual(taps.count, 7)
        XCTAssertEqual(taps.filter { $0.arrayValue?[6] == 1 }.count, 1, "one dead tap")
        XCTAssertEqual(taps.filter { $0.arrayValue?[6] == 2 }.count, 1, "the burst's third tap carries rage")
        let bands = try XCTUnwrap(fiche["at"]?.arrayValue)
        XCTAssertGreaterThan(bands.compactMap { $0.int64Value }.reduce(0, +), 0)
        let form = try XCTUnwrap(fiche["f"]?.arrayValue?.first)
        XCTAssertEqual(form["s"], "Delivery")
        XCTAssertEqual(form["b"], 1)
        XCTAssertEqual(form["ok"], 1)
        XCTAssertEqual(form["rf"], 1)
        XCTAssertEqual(form["lf"], "postalCode")
        let field = try XCTUnwrap(form["fd"]?.arrayValue?.first?.arrayValue)
        XCTAssertEqual(field[0], "postalCode")
        XCTAssertEqual(field[4], 1, "focused once")
        XCTAssertEqual(field[5], 4000, "4 s of hesitation")
        XCTAssertEqual(field[6], 1)
        XCTAssertEqual(field[7], 2, "format")
        XCTAssertEqual(field[8], 1)
        // Its screen_end carries the engaged time and the scroll.
        let end = try XCTUnwrap(batch["e"]?.arrayValue?.first { $0["k"] == "screen_end" && $0["n"] == "Product page" })
        XCTAssertEqual(end["sc"], 80)
        Harness.export(batch, name: "analysed-screen")
    }

    func testStatesAreNumberedAndReplacedWhileUnsent() {
        let h = Harness()
        Self.fullCollection(h)
        let e = h.boot()
        e.enterForeground()
        e.screen("Home")
        h.advance(seconds: 3)
        // Unsent states replace each other in the queue.
        for _ in 0..<3 {
            e.interaction()
            e.enterBackground()
            e.enterForeground()
        }
        let xs = e.queue.items.filter { $0.kind == .screenView }
        XCTAssertLessThanOrEqual(xs.count, 1)
        // Sent states are numbered; at most 10 per screen view.
        for _ in 0..<15 {
            e.tap(selector: "#a", index: 0, kind: "button", x: 1, y: 1, point: (Double.random(in: 0...300), 10), interactive: true)
            h.advance(seconds: 2)
            e.flush()
        }
        let qs = h.http.batches.flatMap { $0["x"]?.arrayValue ?? [] }.compactMap { $0["q"]?.intValue }
        XCTAssertEqual(qs, Array(1...qs.count))
        XCTAssertLessThanOrEqual(qs.count, 10)
    }

    func testSamplingRuleIsTheServers() {
        var c = RemoteConfig()
        c.aa = 10
        XCTAssertTrue(c.samples(session: String(format: "%016llx", UInt64(205))))  // 205 mod 100 = 5
        XCTAssertFalse(c.samples(session: String(format: "%016llx", UInt64(250))))
        c.aa = 0
        XCTAssertFalse(c.samples(session: "0000000000000000"))
    }

    func testScrollDepthRounding() {
        let v = ScreenView(session: "a", number: 1, name: "x", start: 0, analysed: false)
        XCTAssertEqual(v.scrollDepth, 100, "no scroll container")
        v.scrolled(from: 0, to: 0.62, contentHeight: 1000, now: 10, userScroll: false)
        XCTAssertEqual(v.scrollDepth, 60)
        v.scrolled(from: 0.3, to: 0.638, contentHeight: 1000, now: 20, userScroll: true)
        XCTAssertEqual(v.scrollDepth, 65)
    }

    func testEngagementWindow() {
        let v = ScreenView(session: "a", number: 1, name: "x", start: 0, analysed: true)
        v.advance(to: 90_000)
        XCTAssertEqual(v.engagedMs, 60_000, "engaged for 60 s after the screen appeared")
        XCTAssertEqual(v.visibleMs, 90_000)
        v.interaction(at: 100_000)
        v.setForeground(false, now: 110_000)
        v.advance(to: 500_000)
        XCTAssertEqual(v.engagedMs, 70_000, "nothing counts in the background")
    }
}

/// A wrapper that measures its own screens (Flutter, docs/MOBILE.md §17): the engine keeps sessions and transport.
final class WrapperTests: XCTestCase {
    private func boot(_ h: Harness, seen: @escaping (ScruterBridgeScreen) -> Void) -> Engine {
        AnalysedTests.fullCollection(h)
        h.bootConfigFirst(listener: seen)
        return h.engine
    }

    func testTheWrapperIsToldAndOwnsTheMeasures() throws {
        let h = Harness()
        var seen: [ScruterBridgeScreen] = []
        let e = boot(h) { seen.append($0) }
        e.enterForeground()
        e.screen("/cart")
        let first = try XCTUnwrap(seen.first)
        XCTAssertEqual(first.name, "/cart")
        XCTAssertTrue(first.analysed)
        XCTAssertFalse(first.capture)
        XCTAssertNil(e.screenView, "no native measure: Flutter is one view to UIKit")
        e.wrapperScreenEnd(session: first.session, name: "/cart", engagedMs: 4200, depth: 80)
        e.wrapperAnalysed(
            session: first.session,
            body: ["s": .string(first.session), "k": 7, "q": 1, "n": "/cart", "t": .int(first.startMs), "sd": 80])
        e.screen("/done")
        e.flush()
        let batch = try XCTUnwrap(h.http.batches.last)
        let ends = (batch["e"]?.arrayValue ?? []).filter { $0["k"] == "screen_end" }
        XCTAssertEqual(ends.count, 1, "only the wrapper's")
        XCTAssertEqual(ends.first?["ms"], 4200)
        XCTAssertEqual(ends.first?["sc"], 80)
        XCTAssertEqual(batch["x"]?.arrayValue?.count, 1)
    }

    func testOutsideTheSampleAStateIsDropped() throws {
        let h = Harness()
        var seen: [ScruterBridgeScreen] = []
        h.bootConfigFirst(listener: { seen.append($0) })
        let e = h.engine!
        e.enterForeground()
        e.screen("/cart")
        let s = try XCTUnwrap(seen.first)
        XCTAssertFalse(s.analysed)
        e.wrapperAnalysed(session: s.session, body: ["s": .string(s.session), "k": 7, "q": 1, "n": "/cart", "t": .int(s.startMs)])
        e.flush()
        XCTAssertNil(h.http.batches.last?["x"])
    }

    func testADartErrorNamesItsSnapshot() throws {
        let h = Harness()
        let e = boot(h) { _ in }
        e.enterForeground()
        e.reportError(
            kind: "nonfatal", src: "dart", type: "StateError", reason: "Bad state",
            frames: [["a": "0x1234", "i": 0]], debugIds: ["bld": "7d7673e24f49333c"],
            images: [["n": "App", "u": "7d7673e24f49333c", "la": "0x0", "ar": "arm64"]])
        e.flush()
        let report = try XCTUnwrap(h.http.batches.last?["cr"]?.arrayValue?.first)
        XCTAssertEqual(report["bld"], "7d7673e24f49333c")
        XCTAssertEqual(report["img"]?.arrayValue?.first?["n"], "App")
    }
}
