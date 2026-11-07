import Foundation
import XCTest

@testable import ScruterAnalytics

final class EngineTests: XCTestCase {
    func testFirstSessionBatch() throws {
        let h = Harness()
        let e = h.boot()
        XCTAssertEqual(h.http.configRequests.count, 1)
        let configURL = h.http.configRequests[0].url.absoluteString
        XCTAssertTrue(configURL.hasPrefix("https://cdn.scruter.net/m/v1/config?a=ATMONA02&p=ios&av=2.3.0&sv="), configURL)
        e.enterForeground()
        e.screen("Home")
        // The very first session's first screen leaves 2 s later (the live installation check).
        h.advance(seconds: 2)
        XCTAssertEqual(h.http.batches.count, 1)
        h.advance(seconds: 40)
        e.screen("Product page")
        h.advance(seconds: 5)
        e.track("Add to cart", props: ["color": "blue", "quantity": 2, "promo": true, "price": 34.5], revenue: 34.0, currency: "eur")
        h.advance(seconds: 31)
        let batches = h.http.batches
        XCTAssertEqual(batches.count, 2)
        let first = batches[0]
        XCTAssertEqual(first["v"], 1)
        XCTAssertEqual(first["a"], "ATMONA02")
        XCTAssertEqual(first["sdk"], .string("ios/" + scruterSDKVersion))
        XCTAssertEqual(first["ce"], "etag1")
        let s1 = try XCTUnwrap(first["s"]?.arrayValue?.first)
        XCTAssertEqual(s1["q"], 1)
        XCTAssertEqual(s1["n"], 1)
        XCTAssertEqual(s1["i"]?.stringValue, Day.string(ms: h.scheduler.now, zone: TimeZone(identifier: "Europe/Paris")!))
        XCTAssertEqual(s1["ins"], ["src": "app_store"])
        XCTAssertEqual(s1["o"], ["k": "icon"])
        XCTAssertNil(s1["pv"])
        XCTAssertEqual(s1["d"]?.stringValue?.count, 32)
        XCTAssertEqual(s1["id"]?.stringValue?.count, 16)

        let second = batches[1]
        let s2 = try XCTUnwrap(second["s"]?.arrayValue?.first)
        XCTAssertEqual(s2["id"], s1["id"])
        XCTAssertEqual(s2["d"], s1["d"])
        XCTAssertEqual(s2["q"], 2)
        XCTAssertEqual(s2["pv"], s1["c"])
        XCTAssertNil(s2["ins"], "the install source is sent once")
        XCTAssertEqual(s2["c"]?["sv"], 2)
        XCTAssertEqual(s2["c"]?["ev"], 1)
        XCTAssertEqual(s2["c"]?["en"], "Home")
        XCTAssertEqual(s2["c"]?["ex"], "Product page")
        XCTAssertEqual(s2["c"]?["rev"], ["EUR": 3400])
        XCTAssertEqual(s2["c"]?["dur"], 72)
        let events = try XCTUnwrap(second["e"]?.arrayValue)
        XCTAssertEqual(events.map { $0["k"] }, ["screen_end", "screen", "event"])
        XCTAssertEqual(events[0]["n"], "Home")
        XCTAssertEqual(events[0]["sc"], 100)
        XCTAssertEqual(events[0]["ms"], 42000)
        XCTAssertEqual(events[2]["p"], ["color": "blue", "quantity": "2", "promo": "true", "price": "34.5"])
        XCTAssertEqual(events[2]["$"], ["a": 34.0, "c": "EUR"])
        Harness.export(first, name: "first-session")
        Harness.export(second, name: "session-update")
    }

    func testTheInstallNamesWhereApplesPostbackCopiesGo() throws {
        let h = Harness()
        h.device.copyEndpoint = "https://scruter.net"
        let e = h.boot()
        e.enterForeground()
        e.screen("Home")
        h.advance(seconds: 2)
        let first = try XCTUnwrap(h.http.batches.first)
        let s = try XCTUnwrap(first["s"]?.arrayValue?.first)
        XCTAssertEqual(s["ins"], ["src": "app_store", "cp": "https://scruter.net"])
    }

    func testRevenueWithoutCurrencyIsNotRecorded() {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        e.track("Order", props: nil, revenue: 49, currency: nil)
        e.flush()
        let b = h.http.batches.last!
        XCTAssertNil(b["e"]?.arrayValue?.first?["$"])
        XCTAssertEqual(b["s"]?.arrayValue?.first?["c"]?["rev"], .object([:]))
    }

    func testRetriesResendTheSameBatch() throws {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        h.http.respond = { req in
            req.url.path.hasSuffix("batch") ? HTTPResponse(status: 503, headers: ["retry-after": "7"], body: Data()) : nil
        }
        e.screen("Home")
        h.advance(seconds: 2)
        XCTAssertEqual(h.http.batches.count, 1)
        e.screen("Cart")
        h.advance(seconds: 6)
        XCTAssertEqual(h.http.batches.count, 1, "Retry-After is honoured")
        h.advance(seconds: 2)
        XCTAssertEqual(h.http.batches.count, 2)
        XCTAssertEqual(h.http.batches[0], h.http.batches[1], "the same batch, byte for byte")
        // Network errors: exponential backoff from 5 s.
        h.http.respond = { _ in nil }
        h.advance(seconds: 15)
        let n = h.http.batches.count
        XCTAssertGreaterThan(n, 2)
        // A refused batch (400) is dropped and the next one restarts from the acknowledged state.
        h.http.respond = { _ in HTTPResponse(status: 400, headers: [:], body: Data()) }
        h.advance(seconds: 700)
        XCTAssertTrue(e.queue.isEmpty)
        XCTAssertNil(e.inflight)
        h.http.respond = { _ in HTTPResponse(status: 202, headers: [:], body: Data("{}".utf8)) }
        e.track("After", props: nil, revenue: nil, currency: nil)
        e.flush()
        let next = h.http.batches.last!
        XCTAssertEqual(next["s"]?.arrayValue?.first?["q"], 1, "nothing was acknowledged: still state 1")
        XCTAssertEqual(next["e"]?.arrayValue?.count, 1)
    }

    func testSessionTimeoutAndContinuation() {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        e.screen("Home")
        let first = e.current!.id
        let daily = e.current!.daily
        e.enterBackground()
        h.advance(seconds: 29 * 60)
        e.enterForeground()
        XCTAssertEqual(e.current!.id, first, "back within 30 minutes: the same session")
        e.enterBackground()
        h.advance(seconds: 30 * 60)
        e.enterForeground()
        XCTAssertNotEqual(e.current!.id, first)
        XCTAssertEqual(e.current!.current.sv, 1, "the screen on display opens the new session")
        XCTAssertEqual(e.current!.firstAfterInstall, false)
        XCTAssertEqual(e.current!.daily, daily, "the same day keeps the daily id")
    }

    func testDailyIdTurnsAtTheAppsMidnight() {
        let h = Harness()
        // 2026-11-05 22:59:00 UTC = 23:59 in Paris.
        h.scheduler.now = 1_793_919_540_000
        let e = h.boot()
        e.enterForeground()
        let d1 = e.current!.daily
        let install = e.current!.installDay
        e.enterBackground()
        h.advance(seconds: 31 * 60)
        e.enterForeground()
        XCTAssertNotEqual(e.current!.daily, d1)
        XCTAssertEqual(e.current!.installDay, install, "the install day stays")
        XCTAssertEqual(install, "2026-11-05")
    }

    func testUpdateThatAddsTheSDKIsNotAnInstall() {
        let h = Harness()
        h.device.containerCreatedMs = h.scheduler.now - 3 * 24 * 3600 * 1000
        let e = h.boot()
        e.enterForeground()
        e.screen("Home")
        e.flush()
        let s = h.http.batches.last!["s"]!.arrayValue!.first!
        XCTAssertNil(s["i"])
        XCTAssertEqual(s["n"], 0)
        XCTAssertNil(s["ins"])
    }

    func testProcessDeathResendsTheBatchInFlightAndEndsTheSession() throws {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        h.http.hold = true
        e.screen("Home")
        h.advance(seconds: 2)
        let sent = try XCTUnwrap(h.http.batches.first)
        let sessionId = e.current!.id
        e.persistAll()
        // The process dies here; a new one starts on the same files.
        h.http.hold = false
        h.http.requests = []
        let e2 = h.boot()
        h.advance(seconds: 1)
        XCTAssertEqual(h.http.batches.first, sent)
        XCTAssertTrue(e2.sessions.first { $0.id == sessionId }!.ended)
        XCTAssertTrue(e2.sessions.first { $0.id == sessionId }!.diedOpen)
        e2.enterForeground()
        XCTAssertNotEqual(e2.current!.id, sessionId, "a new launch is a new session")
    }

    func testOptOutSendsNothingAndForgets() throws {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        e.screen("Home")
        e.optOut()
        let before = h.http.requests.count
        e.screen("Cart")
        e.track("x", props: nil, revenue: nil, currency: nil)
        e.flush()
        h.advance(seconds: 3600)
        XCTAssertEqual(h.http.requests.count, before)
        XCTAssertTrue(e.queue.isEmpty)
        let state = String(decoding: try Data(contentsOf: h.dir.appendingPathComponent("state.json")), as: UTF8.self)
        XCTAssertFalse(state.contains("daily"))
        XCTAssertFalse(state.contains("install_day"))
        XCTAssertTrue(state.contains("\"opted_out\":true"))
        // A relaunch stays opted out, without even the configuration request.
        h.http.requests = []
        let e2 = h.boot()
        e2.enterForeground()
        e2.screen("Home")
        h.advance(seconds: 60)
        XCTAssertTrue(h.http.requests.isEmpty)
        // Opting in starts as a new install without an install day.
        e2.optIn()
        e2.screen("Home")
        e2.flush()
        let s = h.http.batches.last!["s"]!.arrayValue!.first!
        XCTAssertNil(s["i"])
        XCTAssertEqual(s["n"], 0)
    }

    func testConfigurationOffAndIgnoredScreens() {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        e.screen("DebugMenu")
        e.screen("Home")
        e.flush()
        let names = h.http.batches.flatMap { $0["e"]?.arrayValue ?? [] }.compactMap { $0["n"]?.stringValue }
        XCTAssertFalse(names.contains("DebugMenu"))
        XCTAssertTrue(names.contains("Home"))
        // The kill switch: nothing kept, nothing sent.
        h.http.respond = { req in
            req.url.path.hasSuffix("config")
                ? HTTPResponse(status: 200, headers: [:], body: Data(#"{"v":1,"on":0,"e":"0","ttl":300}"#.utf8))
                : HTTPResponse(status: 202, headers: [:], body: Data("{}".utf8))
        }
        e.fetchConfig()
        let n = h.http.batches.count
        e.screen("Cart")
        e.flush()
        h.advance(seconds: 100)
        XCTAssertEqual(h.http.batches.count, n)
        XCTAssertTrue(e.queue.isEmpty)
    }

    func testStaleConfigurationIsFetchedAgainOnR() {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        h.http.respond = { req in
            req.url.path.hasSuffix("config")
                ? HTTPResponse(status: 304, headers: [:], body: Data())
                : HTTPResponse(status: 202, headers: [:], body: Data(#"{"r":1}"#.utf8))
        }
        e.screen("Home")
        e.flush()
        XCTAssertEqual(h.http.configRequests.count, 2)
        XCTAssertEqual(h.http.configRequests[1].headers["If-None-Match"], "\"etag1\"")
    }

    func testGzipAboveOneKilobyte() {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        for i in 0..<30 { e.track("Event \(i)", props: ["k": String(repeating: "v", count: 40)], revenue: nil, currency: nil) }
        e.flush()
        let req = h.http.requests.last { $0.url.path.hasSuffix("batch") }!
        XCTAssertEqual(req.headers["Content-Encoding"], "gzip")
        XCTAssertEqual(h.http.batches.last?["e"]?.arrayValue?.count, 30)
    }

    func testBatchLimitsSplitTheQueue() {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        h.http.hold = true
        for i in 0..<450 { e.track("e\(i)", props: nil, revenue: nil, currency: nil) }
        h.http.hold = false
        h.http.release(HTTPResponse(status: 202, headers: [:], body: Data("{}".utf8)))
        e.flush()
        let sizes = h.http.batches.map { $0["e"]?.arrayValue?.count ?? 0 }
        XCTAssertTrue(sizes.allSatisfy { $0 <= 200 }, "\(sizes)")
        XCTAssertEqual(sizes.reduce(0, +), 450)
        XCTAssertTrue(e.queue.isEmpty)
    }

    func testQueueLimitsAndAge() {
        let h = Harness()
        let store = FileStore(directory: h.dir)
        let q = PersistentQueue(store: store)
        for i in 0..<(PersistentQueue.maxItems + 10) {
            q.append(kind: .event, session: "s", time: Int64(i), body: ["n": .int(Int64(i))])
        }
        XCTAssertEqual(q.count, PersistentQueue.maxItems)
        XCTAssertEqual(q.items.first?.body["n"], 10, "the oldest dropped first")
        q.save()
        let reloaded = PersistentQueue(store: store)
        XCTAssertEqual(reloaded.count, PersistentQueue.maxItems)
        XCTAssertEqual(reloaded.dropExpired(now: PersistentQueue.maxAgeMs + 100), 90)
        for i in 0..<12 { reloaded.append(kind: .crash, session: "s", time: Int64(1e12) + Int64(i), body: ["i": .int(Int64(i))]) }
        XCTAssertEqual(reloaded.items.filter { $0.kind == .crash }.count, PersistentQueue.maxCrashes)
    }

    func testOpeningFromALink() {
        let h = Harness()
        let e = h.boot()
        e.enterForeground()
        e.handle(url: URL(string: "https://atelier-mona.fr/shop?utm_source=newsletter&token=secret#x")!)
        e.screen("Shop")
        e.flush()
        let o = h.http.batches.last!["s"]!.arrayValue!.first!["o"]!
        XCTAssertEqual(o, ["k": "link", "u": "https://atelier-mona.fr/shop?utm_source=newsletter"])
        Harness.export(h.http.batches.last!, name: "link-opening")
        XCTAssertEqual(Links.openingKind(URL(string: "atmona://cart?scruter_open=widget")!), "widget")
    }

    func testDebugBuildSendsFirstScreenSoonAndFlagsDebug() {
        let h = Harness()
        h.device.buildKind = "debug"
        h.device.isDebugBuild = true
        h.options.debug = true
        let e = h.boot()
        e.enterForeground()
        e.screen("Home")
        h.advance(seconds: 2)
        let b = h.http.batches.last!
        XCTAssertEqual(b["dbg"], 1)
        XCTAssertEqual(b["s"]?.arrayValue?.first?["bk"], "debug")
        XCTAssertTrue(h.logs.contains { $0.contains("screen Home") })
    }
}
