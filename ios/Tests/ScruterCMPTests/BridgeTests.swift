import Foundation
import XCTest

@testable import ScruterCMP

/// What the React Native and Flutter wrappers read and hear (Bridge.swift, docs/CMP-MOBILE.md §3.16).
final class BridgeTests: XCTestCase {
    private var events: [([String: Any], Bool)] = []

    override func setUp() {
        CMPBridge.shared.reset()
        CMPBridge.active = true
        events = []
        CMPBridge.shared.setListener { [weak self] s, fresh in self?.events.append((s, fresh)) }
    }

    override func tearDown() {
        CMPBridge.active = false
        CMPBridge.shared.reset()
    }

    private var snapshot: [String: Any] { CMPBridge.shared.current() }

    func testNothingBeforeAStart() {
        CMPBridge.shared.reset()
        let s = CMPBridge.snapshot(nil, optional: [])
        XCTAssertEqual(s["state"] as? String, "unavailable")
        XCTAssertEqual(s["granted"] as? [String], ["necessary"])
        XCTAssertNil(s["choice"])
        let signals = s["signals"] as? [String: String]
        XCTAssertEqual(signals?["security_storage"], "granted")
        XCTAssertEqual(signals?["analytics_storage"], "denied")
    }

    func testFirstDecisionThenPreferencesThenWithdrawal() throws {
        let h = Harness()
        h.start()
        XCTAssertEqual(snapshot["state"] as? String, "needsDecision")
        XCTAssertNil(snapshot["choice"])
        XCTAssertTrue(events.allSatisfy { !$0.1 }, "no choice yet")

        h.decide(.custom, granted: ["analytics"])
        let first = try XCTUnwrap(events.last)
        XCTAssertTrue(first.1, "a new valid choice")
        let choice = try XCTUnwrap(first.0["choice"] as? [String: Any])
        XCTAssertEqual(choice["granted"] as? [String], ["analytics", "necessary"])
        XCTAssertEqual(choice["denied"] as? [String], ["advertising"])
        XCTAssertEqual(choice["consentId"] as? String, first.0["consentId"] as? String)
        XCTAssertEqual((choice["decidedAt"] as? Int64).map { $0 % 1000 }, 0, "milliseconds")
        XCTAssertEqual(first.0["state"] as? String, "ready")
        XCTAssertEqual((first.0["signals"] as? [String: String])?["analytics_storage"], "granted")
        XCTAssertEqual((first.0["signals"] as? [String: String])?["ad_storage"], "denied")
        XCTAssertEqual(events.filter { $0.1 }.count, 1)

        h.engine.showPreferences(anchor: nil)
        h.decide(.acceptAll, granted: ["analytics", "advertising"], source: .preferences)
        XCTAssertEqual(events.filter { $0.1 }.count, 2)
        XCTAssertEqual((events.last?.0["choice"] as? [String: Any])?["denied"] as? [String], [])

        h.engine.showPreferences(anchor: nil)
        h.decide(.rejectAll, granted: [], source: .preferences)
        XCTAssertEqual(events.filter { $0.1 }.count, 3, "a withdrawal is a change")
        XCTAssertEqual(snapshot["granted"] as? [String], ["necessary"])
    }

    func testAReturningVisitorIsReadyAtOnceAndAnUnchangedSnapshotIsNotRepeated() throws {
        let h = Harness()
        h.start()
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        CMPBridge.shared.reset()
        CMPBridge.shared.setListener { [weak self] s, fresh in self?.events.append((s, fresh)) }
        events = []
        let again = h.relaunch()
        again.start()
        XCTAssertEqual(events.filter { $0.1 }.count, 1, "the stored choice, once")
        XCTAssertEqual(snapshot["state"] as? String, "ready")
        let n = events.count
        again.engine.didEnterBackground()
        again.engine.willEnterForeground()
        XCTAssertEqual(events.count, n, "nothing changed, nothing told")
    }

    func testAReaskSaysTheStateWithoutANewChoice() throws {
        let h = Harness()
        h.start()
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
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
        CMPBridge.shared.reset()
        CMPBridge.shared.setListener { [weak self] s, fresh in self?.events.append((s, fresh)) }
        events = []
        let h2 = h.relaunch()
        h2.start()
        XCTAssertEqual(snapshot["state"] as? String, "needsDecision")
        XCTAssertNil(snapshot["choice"])
        XCTAssertEqual(snapshot["granted"] as? [String], ["analytics", "necessary"], "the unchanged purpose keeps its answer")
        XCTAssertEqual(events.last?.1, false, "the re-ask is a state, not a choice")
        let before = events.filter { $0.1 }.count
        h2.decide(nil, granted: ["analytics"])
        XCTAssertEqual(events.filter { $0.1 }.count, before + 1, "the answer to a re-ask is a new choice")
        XCTAssertEqual((events.last?.0["choice"] as? [String: Any])?["denied"] as? [String], ["advertising"])
    }

    func testAReplacedListenerIsTheOnlyOneTold() {
        let h = Harness()
        h.start()
        var other = 0
        CMPBridge.shared.setListener { _, _ in other += 1 }
        let before = events.count
        h.decide(.rejectAll, granted: [])
        XCTAssertEqual(events.count, before, "a reload replaces the listener")
        XCTAssertGreaterThan(other, 0)
    }
}
