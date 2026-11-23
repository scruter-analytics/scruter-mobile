import Foundation
import XCTest

@testable import ScruterCMP

/// The engine on a fake ingest: openings, decisions, proofs, re-asks, the queue, detected SDKs (docs/CMP-MOBILE.md §3).
final class EngineTests: XCTestCase {
    private func json(_ d: Data?) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d ?? Data())) as? [String: Any] ?? [:] }

    // MARK: First launch

    func testFirstLaunchShowsTheSheetAndProvesTheDecision() throws {
        let h = Harness()
        let e = h.start()
        XCTAssertEqual(h.ingest.count("/m/v1/cmp"), 1)
        let q = try XCTUnwrap(h.ingest.requests.first?.url.query)
        XCTAssertTrue(q.contains("a=ATMONA02") && q.contains("p=ios") && q.contains("av=2.3.0") && q.contains("sv=1.1.0"), q)
        XCTAssertEqual(e.snapshot.state, .needsDecision)
        XCTAssertFalse(e.isGranted("analytics"))
        XCTAssertTrue(e.isGranted("necessary"))
        let m = try XCTUnwrap(h.host.shown.first)
        XCTAssertEqual(m.kind, .banner)
        XCTAssertEqual(m.lang, "fr")
        XCTAssertEqual(m.purposes.map { $0.key }, ["analytics", "advertising"])
        XCTAssertEqual(m.purposes[1].providers, ["Google Mobile Ads", "Meta"])
        XCTAssertEqual(m.policyURL, "https://atelier-mona.fr/confidentialite")
        XCTAssertEqual(m.granted, [])
        XCTAssertTrue(m.closeLink)
        XCTAssertFalse(m.twoButtons)
        // French spacing on display only.
        XCTAssertEqual(h.ingest.bodies("/cmp/hit").count, 0, "the hit waits for the sheet")
        XCTAssertTrue(h.host.prefetched.contains { $0.hasSuffix(".jpg") })

        e.sheetDidAppear(.banner)
        let hit = try XCTUnwrap(h.ingest.bodies("/cmp/hit").first)
        XCTAssertEqual(hit["d"] as? Int, 1)
        XCTAssertEqual(hit["b"] as? Int, 412)
        XCTAssertEqual(hit["l"] as? String, "fr")
        XCTAssertEqual(hit["w"] as? Int, 393)
        XCTAssertEqual(hit["cv"] as? String, "ios/1.1.0")
        XCTAssertEqual(hit["ap"] as? String, "fr.ateliermona.app")
        XCTAssertNil(hit["dbg"])
        Kit.record("cmp-hit", "first-launch", h.ingest.requests.last { $0.url.path == "/cmp/hit" }!.body!)

        h.scheduler.advance(2400)
        h.ingest.hold = true
        e.decide(SheetDecision(action: .acceptAll, granted: ["analytics", "advertising"], source: .banner), model: m)
        let stored = try XCTUnwrap(StoredChoice.parse(h.choice.value ?? ""))
        XCTAssertEqual(stored.granted, ["analytics", "advertising"])
        XCTAssertEqual(stored.pending, .init(action: .acceptAll, source: .banner))
        XCTAssertEqual(stored.banner, 412)
        XCTAssertEqual(stored.rev, 3)
        XCTAssertTrue(e.isGranted("advertising"))
        XCTAssertEqual(e.snapshot.state, .ready)

        let req = try XCTUnwrap(h.ingest.held.first?.0)
        XCTAssertEqual(req.url.absoluteString, "https://cdn.scruter.net/cmp/consent")
        let proof = json(req.body)
        XCTAssertEqual(proof["c"] as? String, "accept_all")
        XCTAssertEqual(proof["o"] as? String, "banner")
        XCTAssertEqual(proof["i"] as? String, stored.id)
        XCTAssertEqual(proof["g"] as? [String], ["analytics", "advertising"])
        XCTAssertEqual(proof["n"] as? [String], [])
        XCTAssertEqual(proof["m"] as? [String], ["ad_storage", "ad_user_data", "ad_personalization", "analytics_storage", "security_storage"])
        XCTAssertEqual(proof["h"] as? String, "60e37e780048000a8255e6353a442ecde77e949aa68b6e19205e21945c4958a1")
        XCTAssertEqual(proof["ms"] as? Int, 2400)
        XCTAssertEqual(proof["r"] as? Int, 3)
        Kit.record("cmp-consent", "accept-all", req.body!)

        h.ingest.hold = false
        h.ingest.release()
        XCTAssertNil(StoredChoice.parse(h.choice.value ?? "")?.pending, "acknowledged")
        XCTAssertEqual(StoredChoice.parse(h.choice.value ?? "")?.id, stored.id)
    }

    /// §3.1, §3.11: on the caller's thread, `start` reads the stored choice once and touches nothing else.
    func testTheCallersThreadReadsTheChoiceOnly() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmp-untouched-" + UUID().uuidString)
        let choice = MemoryChoice()
        choice.value = "1.cns_8f2a41c9e7b3d0a1f2c4.tlpwu8.3.412.analytics."
        let http = FakeIngest()
        let env = CMPEnvironment(
            scheduler: ManualScheduler(), http: http, choice: choice, files: CMPFiles(directory: dir), device: CMPDevice())
        let e = CMPEngine(env: env, options: .init(appId: "ATMONA02", base: URL(string: "https://cdn.scruter.net")!, automatic: true), queue: DispatchQueue(label: "t"))
        XCTAssertTrue(e.isGranted("analytics"))
        XCTAssertEqual(choice.reads, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "no file read or written before the queue runs")
        XCTAssertTrue(http.requests.isEmpty, "no network")
    }

    func testOfflineFirstLaunchGrantsNothingThenAsksWhenTheNetworkReturns() {
        let h = Harness()
        h.ingest.offline = true
        let e = h.start()
        XCTAssertEqual(e.snapshot.state, .unavailable)
        XCTAssertFalse(e.isGranted("analytics"))
        XCTAssertTrue(h.host.shown.isEmpty)
        h.ingest.offline = false
        e.networkAvailable()
        XCTAssertEqual(e.snapshot.state, .needsDecision)
        XCTAssertEqual(h.host.shown.count, 1)
    }

    func testCMPOffShowsNothingAndGrantsNothing() {
        let h = Harness()
        h.choice.value = "1.cns_8f2a41c9e7b3d0a1f2c4.tlpwu8.3.412.analytics."
        h.ingest.config = Kit.data("bodies/config-off.json")
        let e = h.start()
        XCTAssertEqual(e.snapshot.state, .unavailable)
        XCTAssertFalse(e.isGranted("analytics"))
        XCTAssertTrue(h.host.shown.isEmpty)
        XCTAssertEqual(h.ingest.bodies("/cmp/hit").count, 0)
    }

    // MARK: Later launches

    func testAValidChoiceAnswersSynchronouslyAndSendsAnOpening() throws {
        let h = Harness()
        let first = h.start()
        h.decide(.custom, granted: ["analytics"])
        XCTAssertTrue(first.isGranted("analytics"))

        let h2 = h.relaunch()
        h2.scheduler.advance(3_600_000)
        h2.ingest.hold = true
        let e = h2.start()
        XCTAssertTrue(e.isGranted("analytics"), "from the stored value, before any network")
        XCTAssertFalse(e.isGranted("advertising"))
        XCTAssertEqual(e.snapshot.state, .ready)
        XCTAssertTrue(h2.host.shown.isEmpty)
        let hit = try XCTUnwrap(h2.ingest.held.first { $0.0.url.path == "/cmp/hit" })
        XCTAssertEqual(json(hit.0.body)["d"] as? Int, 0)
        XCTAssertEqual(h2.choice.writes, 0, "nothing written at a launch with a valid choice")
    }

    func testOpeningsCountColdStartsAndReturnsAfterThirtyMinutes() {
        let h = Harness()
        let e = h.start()
        h.decide(.rejectAll, granted: [])
        XCTAssertEqual(h.ingest.bodies("/cmp/hit").count, 1)
        e.didEnterBackground()
        h.scheduler.advance(10 * 60 * 1000)
        e.willEnterForeground()
        XCTAssertEqual(h.ingest.bodies("/cmp/hit").count, 1, "10 minutes: the same opening")
        e.didEnterBackground()
        h.scheduler.advance(31 * 60 * 1000)
        e.willEnterForeground()
        XCTAssertEqual(h.ingest.bodies("/cmp/hit").count, 2)
        XCTAssertEqual(h.ingest.bodies("/cmp/hit").last?["d"] as? Int, 0)
    }

    func testAnOpeningWithoutDisplayIsCountedAtTheBackground() {
        let h = Harness()
        h.automatic = false
        let e = h.start()
        XCTAssertEqual(e.snapshot.state, .needsDecision)
        XCTAssertTrue(h.host.shown.isEmpty, "manual presentation")
        XCTAssertEqual(h.ingest.bodies("/cmp/hit").count, 0)
        e.didEnterBackground()
        XCTAssertEqual(h.ingest.bodies("/cmp/hit").first?["d"] as? Int, 0)
        e.showIfNeeded(anchor: nil)
        XCTAssertEqual(h.host.shown.count, 1)
    }

    // MARK: Re-ask (§3.8)

    func testReaskAfterANewConfigurationKeepsTheUnchangedPurposes() throws {
        let h = Harness()
        h.start()
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        let id = StoredChoice.parse(h.choice.value!)!.id
        h.scheduler.advance(2 * 3_600_000)
        h.ingest.config = config { c in
            editConfig(&c) { cfg in
                cfg["consent_rev"] = 4
                cfg["purposes"] = [
                    ["key": "necessary", "required": true, "rev": 1], ["key": "analytics", "required": false, "rev": 3],
                    ["key": "advertising", "required": false, "rev": 4],
                ]
            }
        }
        let h2 = h.relaunch()
        let e = h2.start()
        XCTAssertEqual(e.snapshot.state, .needsDecision)
        XCTAssertTrue(e.isGranted("analytics"), "unchanged: kept until the new decision")
        XCTAssertFalse(e.isGranted("advertising"), "its meaning changed")
        let m = try XCTUnwrap(h2.host.shown.first)
        XCTAssertEqual(m.granted, ["analytics"], "the steps start from the kept answers")
        h2.decide(nil, granted: ["analytics"])
        let s = StoredChoice.parse(h2.choice.value!)!
        XCTAssertEqual(s.id, id, "a device keeps its consent id across re-asks")
        XCTAssertEqual(s.rev, 4)
        XCTAssertEqual(h2.ingest.bodies("/cmp/consent").last?["c"] as? String, "custom")
    }

    func testTheReconsentPeriodRunsOutAtForeground() {
        let h = Harness()
        let e = h.start()
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        e.didEnterBackground()
        h.scheduler.advance(Rules.renewSeconds(6) * 1000 + 1000)
        e.willEnterForeground()
        XCTAssertEqual(e.snapshot.state, .needsDecision)
        XCTAssertFalse(e.isGranted("analytics"), "an expired consent grants nothing")
        XCTAssertEqual(h.host.shown.count, 2)
    }

    // MARK: Withdrawal and the preferences (§2.5, §3.3)

    func testWithdrawalFromThePreferences() throws {
        let h = Harness()
        let e = h.start()
        h.decide(.custom, granted: ["analytics"])
        var changes: [ScruterCMP.Choice] = []
        e.addObserver(id: 1) { changes.append($0) }
        e.showPreferences(anchor: nil)
        let m = try XCTUnwrap(h.host.shown.last)
        XCTAssertEqual(m.kind, .preferences)
        XCTAssertEqual(m.granted, ["analytics"])
        XCTAssertEqual(m.consentId, StoredChoice.parse(h.choice.value!)!.id)
        XCTAssertEqual(m.required.map { $0.key }, ["necessary"])
        e.decide(SheetDecision(action: .rejectAll, granted: [], source: .preferences), model: m)
        let proof = try XCTUnwrap(h.ingest.bodies("/cmp/consent").last)
        XCTAssertEqual(proof["c"] as? String, "withdraw")
        XCTAssertEqual(proof["o"] as? String, "preferences")
        XCTAssertEqual(proof["ms"] as? Int, 0)
        XCTAssertEqual(proof["m"] as? [String], ["security_storage"])
        Kit.record("cmp-consent", "withdraw", h.ingest.requests.last { $0.url.path == "/cmp/consent" }!.body!)
        XCTAssertFalse(e.isGranted("analytics"))
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.granted, [])
    }

    func testCloseIsARefusal() {
        let h = Harness()
        h.start()
        h.decide(.close, granted: [])
        let proof = h.ingest.bodies("/cmp/consent").last
        XCTAssertEqual(proof?["c"] as? String, "close")
        XCTAssertEqual(proof?["n"] as? [String], ["analytics", "advertising"])
        Kit.record("cmp-consent", "close", h.ingest.requests.last { $0.url.path == "/cmp/consent" }!.body!)
    }

    func testCallbacks() {
        let h = Harness()
        let e = h.start()
        var ready: [ScruterCMP.Choice] = []
        var changed: [ScruterCMP.Choice] = []
        e.whenReady { ready.append($0) }
        e.addObserver(id: 7) { changed.append($0) }
        XCTAssertTrue(ready.isEmpty)
        h.decide(.custom, granted: ["advertising"])
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.granted, ["advertising"])
        XCTAssertEqual(ready.first?.denied, ["analytics"])
        XCTAssertTrue(changed.isEmpty, "the first decision is `whenReady`'s")
        e.whenReady { ready.append($0) }
        XCTAssertEqual(ready.count, 2, "now, when a choice exists")
        e.showPreferences(anchor: nil)
        h.decide(.acceptAll, granted: ["analytics", "advertising"], source: .preferences)
        XCTAssertEqual(changed.count, 1)
        e.removeObserver(7)
        e.showPreferences(anchor: nil)
        h.decide(.rejectAll, granted: [], source: .preferences)
        XCTAssertEqual(changed.count, 1)
    }

    // MARK: Proofs that do not arrive (§3.3)

    func testProcessKilledDuringTheDecision() throws {
        let h = Harness()
        h.start()
        h.ingest.hold = true
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        // Killed before any answer: the stored value is written, the proof is in the queue file.
        let h2 = h.relaunch()
        let e = h2.start()
        XCTAssertTrue(e.isGranted("advertising"))
        let proofs = h2.ingest.bodies("/cmp/consent")
        XCTAssertEqual(proofs.count, 1)
        XCTAssertEqual(proofs.first?["c"] as? String, "accept_all")
        XCTAssertNil(StoredChoice.parse(h2.choice.value!)?.pending)

        // Killed before even the queue was written: the pending flag rebuilds the proof.
        let h3 = Harness()
        h3.start()
        h3.ingest.hold = true
        h3.decide(.rejectAll, granted: [])
        try FileManager.default.removeItem(at: h3.dir.appendingPathComponent("beacons.json"))
        let h4 = h3.relaunch()
        h4.start()
        let again = try XCTUnwrap(h4.ingest.bodies("/cmp/consent").first)
        XCTAssertEqual(again["c"] as? String, "reject_all")
        XCTAssertEqual(again["ms"] as? Int, 0)
        XCTAssertNil(StoredChoice.parse(h4.choice.value!)?.pending)
    }

    func testAPendingProofOfAReplacedVersionIsDropped() {
        let h = Harness()
        h.choice.value = "1.cns_0123456789abcdef0123.tlpwu8.3.400.analytics.pcb"
        h.start()
        XCTAssertEqual(h.ingest.bodies("/cmp/consent").count, 0)
        XCTAssertNil(StoredChoice.parse(h.choice.value!)?.pending)
    }

    func testRetriesWithBackoffAndRetryAfterThenDropsRefusedBeacons() {
        let h = Harness()
        h.start()
        h.ingest.beaconStatus = 503
        h.ingest.extra = { r in r.url.path == "/cmp/consent" ? CMPResponse(status: 429, headers: ["retry-after": "120"], body: Data()) : nil }
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        let hits = h.ingest.count("/cmp/hit")
        h.scheduler.advance(4000)
        XCTAssertEqual(h.ingest.count("/cmp/hit"), hits, "no retry before the backoff")
        h.ingest.beaconStatus = 202
        h.scheduler.advance(10_000)
        XCTAssertEqual(h.ingest.count("/cmp/hit"), hits + 1)
        let proofs = h.ingest.count("/cmp/consent")
        h.scheduler.advance(60_000)
        XCTAssertEqual(h.ingest.count("/cmp/consent"), proofs, "Retry-After: 120")
        h.ingest.extra = { _ in nil }
        h.scheduler.advance(61_000)
        XCTAssertEqual(h.ingest.count("/cmp/consent"), proofs + 1)
        XCTAssertNil(StoredChoice.parse(h.choice.value!)?.pending)

        let h2 = Harness()
        h2.start()
        h2.ingest.beaconStatus = 400
        h2.decide(.rejectAll, granted: [])
        XCTAssertTrue(h2.engine.beacons.items.isEmpty, "a 400 cannot be fixed by sending again")
    }

    func testBeaconsExpireAfterFortyEightHours() {
        let h = Harness()
        h.start()
        h.ingest.offline = true
        h.decide(.rejectAll, granted: [])
        XCTAssertEqual(h.engine.beacons.items.count, 2)
        h.scheduler.advance(49 * 3_600_000)
        h.ingest.offline = false
        h.engine.networkAvailable()
        XCTAssertTrue(h.engine.beacons.items.isEmpty)
        XCTAssertEqual(h.ingest.bodies("/cmp/consent").count, 0)
    }

    // MARK: Configuration cache

    func testTheConfigurationIsCachedAndRevalidatedWithItsETag() throws {
        let h = Harness()
        h.start()
        h.decide(.rejectAll, granted: [])
        let h2 = h.relaunch()
        h2.scheduler.advance(10_000)
        let e = h2.start()
        XCTAssertEqual(h2.ingest.count("/m/v1/cmp"), 0, "within ttl: the cached configuration")
        XCTAssertEqual(e.snapshot.state, .ready)
        e.didEnterBackground()
        h2.scheduler.advance(3_600_000)
        e.willEnterForeground()
        let req = try XCTUnwrap(h2.ingest.requests.last { $0.url.path.hasSuffix("/m/v1/cmp") })
        XCTAssertEqual(req.headers["If-None-Match"], h2.ingest.etag)
        XCTAssertEqual(e.snapshot.state, .ready)
    }

    // MARK: Languages

    func testAnotherLanguageIsFetchedOnceAndProvedWithItsHash() throws {
        let h = Harness()
        h.device.languages = ["de-DE"]
        let packHash = String(repeating: "ab", count: 32)
        var texts = (Kit.json("bodies/config.json") as! [String: Any])
        texts = ((texts["config"] as! [String: Any])["ui"] as! [String: Any])["texts"] as! [String: Any]
        var de = texts["fr"] as! [String: Any]
        de["title"] = "Ihre Daten, Ihre Wahl"
        let pack = try JSONSerialization.data(withJSONObject: ["lang": "de", "dir": "ltr", "hash": packHash, "texts": de])
        h.ingest.extra = { r in r.url.path == "/cmp/ATMONA02/texts-412-de.json" ? CMPResponse(status: 200, headers: [:], body: pack) : nil }
        let e = h.start()
        let m = try XCTUnwrap(h.host.shown.first)
        XCTAssertEqual(m.lang, "de")
        XCTAssertEqual(m.texts.title, "Ihre Daten, Ihre Wahl")
        XCTAssertEqual(m.words.next, "Weiter")
        e.sheetDidAppear(.banner)
        e.decide(SheetDecision(action: .rejectAll, granted: [], source: .banner), model: m)
        XCTAssertEqual(h.ingest.bodies("/cmp/consent").last?["h"] as? String, packHash)
        XCTAssertEqual(h.ingest.bodies("/cmp/consent").last?["l"] as? String, "de")

        // Cached: no second request.
        let fetched = h.ingest.count("texts-412-de.json")
        e.setLanguage("de")
        e.showPreferences(anchor: nil)
        XCTAssertEqual(h.ingest.count("texts-412-de.json"), fetched)
    }

    func testALanguageThatDoesNotArriveFallsBackAfterTheBudget() throws {
        let h = Harness()
        h.device.languages = ["en"]
        h.ingest.holdPaths = ["texts-"]
        h.start()
        XCTAssertTrue(h.host.shown.isEmpty, "waiting for the English texts")
        h.scheduler.advance(1500)
        let m = try XCTUnwrap(h.host.shown.first)
        XCTAssertEqual(m.lang, "fr")
        XCTAssertEqual(m.texts.accept_all, "Tout accepter")
        h.ingest.release(nil)
        XCTAssertEqual(h.host.shown.count, 1)
    }

    // MARK: A/B tests (docs/CMP.md §7.3)

    func testTheVariantIsDrawnPerOpening() throws {
        let h = Harness()
        h.draw = 10
        h.ingest.config = config { c in
            editConfig(&c) { cfg in
                var b = cfg["ui"] as! [String: Any]
                b["color"] = "#0B3D91"
                b["on_color"] = "#FFFFFF"
                cfg["ab_test"] = ["id": "0192f0c4-8a1b-7c2d-9e3f-4a5b6c7d8e9f", "split_b": 50, "b": ["id": 413, "version": 4], "b_ui": b]
            }
        }
        let e = h.start()
        let m = try XCTUnwrap(h.host.shown.first)
        XCTAssertEqual(m.banner, 413)
        XCTAssertEqual(m.color, "#0B3D91")
        e.sheetDidAppear(.banner)
        let hit = try XCTUnwrap(h.ingest.bodies("/cmp/hit").first)
        XCTAssertEqual(hit["b"] as? Int, 413)
        XCTAssertEqual(hit["a"] as? String, "b")
        XCTAssertEqual(hit["t"] as? String, "0192f0c4-8a1b-7c2d-9e3f-4a5b6c7d8e9f")
        Kit.record("cmp-hit", "variant-b", h.ingest.requests.last { $0.url.path == "/cmp/hit" }!.body!)
        e.decide(SheetDecision(action: .acceptAll, granted: ["analytics", "advertising"], source: .banner), model: m)
        let proof = try XCTUnwrap(h.ingest.bodies("/cmp/consent").last)
        XCTAssertEqual(proof["b"] as? Int, 413)
        XCTAssertEqual(proof["a"] as? String, "b")
        Kit.record("cmp-consent", "variant-b", h.ingest.requests.last { $0.url.path == "/cmp/consent" }!.body!)
        XCTAssertEqual(StoredChoice.parse(h.choice.value!)?.banner, 413)
        // Variant B's version is current: no re-ask at the next launch.
        let h2 = h.relaunch()
        h2.draw = 90
        XCTAssertEqual(h2.start().snapshot.state, .ready)
    }

    // MARK: Detected SDKs (§3.14)

    func testDetectedSDKsAreReportedOncePerAppAndCatalogueVersion() throws {
        let h = Harness()
        h.start()
        let report = try XCTUnwrap(h.ingest.bodies("/m/v1/cmp/sdks").first)
        XCTAssertEqual(report["k"] as? [String], ["firebase_analytics", "google_mobile_ads"])
        XCTAssertEqual(report["c"] as? Int, 1)
        XCTAssertEqual(report["av"] as? String, "2.3.0")
        XCTAssertEqual(report["a"] as? String, "ATMONA02")
        Kit.record("cmp-sdks", "report", h.ingest.requests.last { $0.url.path == "/m/v1/cmp/sdks" }!.body!)
        let h2 = h.relaunch()
        h2.scheduler.advance(3_700_000)
        h2.start()
        XCTAssertEqual(h2.ingest.bodies("/m/v1/cmp/sdks").count, 0)
        XCTAssertEqual(h2.ingest.count("/m/v1/cmp/sdks/1.json"), 0)
        var h3 = h.relaunch()
        h3.device.appVersion = "2.4.0"
        h3.classes = ["AppsFlyerLib"]
        h3.start()
        XCTAssertEqual(h3.ingest.bodies("/m/v1/cmp/sdks").first?["k"] as? [String], ["appsflyer"])
        XCTAssertEqual(h3.ingest.count("/m/v1/cmp/sdks/1.json"), 0, "the catalogue is cached")
        h3 = h
    }

    // MARK: Debug builds (§3.13, §2.5)

    func testDebugBuilds() throws {
        let h = Harness()
        h.device.isDebugBuild = true
        let e = h.start()
        e.sheetDidAppear(.banner)
        XCTAssertEqual(h.ingest.bodies("/cmp/hit").first?["dbg"] as? Int, 1)
        Kit.record("cmp-hit", "debug", h.ingest.requests.last { $0.url.path == "/cmp/hit" }!.body!)
        e.decide(SheetDecision(action: .acceptAll, granted: ["analytics", "advertising"], source: .banner), model: h.host.shown[0])
        XCTAssertEqual(h.ingest.bodies("/cmp/consent").first?["dbg"] as? Int, 1)
        Kit.record("cmp-consent", "debug", h.ingest.requests.last { $0.url.path == "/cmp/consent" }!.body!)

        e.debugReset()
        XCTAssertNil(h.choice.value)
        XCTAssertEqual(e.snapshot.state, .needsDecision)
        XCTAssertEqual(h.host.shown.count, 2, "the sheet shows again")

        // The settings entry: a warning after 10 launches with a choice and no showPreferences().
        h.decide(.rejectAll, granted: [])
        var last = h
        for _ in 0..<10 {
            last = last.relaunch()
            last.start()
        }
        XCTAssertTrue(last.logs.contains { $0.contains("showPreferences() was never called") })
        last.engine.showPreferences(anchor: nil)
        let next = last.relaunch()
        next.start()
        XCTAssertFalse(next.logs.contains { $0.contains("showPreferences() was never called") })
    }

    func testDebugResetDoesNothingInARelease() {
        let h = Harness()
        let e = h.start()
        h.decide(.rejectAll, granted: [])
        e.debugReset()
        XCTAssertNotNil(h.choice.value)
    }

    func testForceShowShowsAValidChoice() {
        let h = Harness()
        h.start()
        h.decide(.rejectAll, granted: [])
        let h2 = h.relaunch()
        h2.scheduler.advance(1000)
        let e = CMPEngineForceShow(h2)
        XCTAssertEqual(e.snapshot.state, .ready)
        XCTAssertEqual(h2.host.shown.count, 1)
    }

    private func CMPEngineForceShow(_ h: Harness) -> CMPEngine {
        // forceShow is set before start, as the public API does.
        h.log.enabled = true
        let env = CMPEnvironment(
            now: { [s = h.scheduler] in s.now }, scheduler: h.scheduler, http: h.ingest, choice: h.choice,
            files: CMPFiles(directory: h.dir), log: h.log, device: h.device)
        let e = CMPEngine(env: env, options: .init(appId: "ATMONA02", base: URL(string: "https://cdn.scruter.net")!, automatic: true), queue: .main)
        e.host = h.host
        e.forceShow = true
        e.start()
        return e
    }
}
