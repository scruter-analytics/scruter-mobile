import Foundation
import XCTest

@testable import ScruterCMP

/// The conformance kit's vectors (`sdk/protocol/cmp/vectors/`), which the site script passes too.
final class KitTests: XCTestCase {
    private func stored(_ j: Any?) -> StoredChoice? {
        guard let o = j as? [String: Any] else { return nil }
        var pending: StoredChoice.Pending?
        if let p = o["pending"] as? [String: String] {
            pending = .init(action: CMPAction(rawValue: p["action"]!)!, source: CMPSource(rawValue: p["source"]!)!)
        }
        return StoredChoice(
            id: o["id"] as! String, at: (o["at"] as! NSNumber).int64Value, rev: o["rev"] as! Int, banner: o["banner"] as! Int,
            granted: o["granted"] as! [String], pending: pending)
    }

    func testStoredValueVectors() {
        let v = Kit.json("vectors/stored-value.json") as! [String: Any]
        let valid = v["valid"] as! [[String: Any]]
        XCTAssertGreaterThan(valid.count, 5)
        for c in valid {
            let value = c["value"] as! String
            let expected = stored(c["stored"])!
            XCTAssertEqual(StoredChoice.parse(value), expected, c["note"] as! String)
            XCTAssertEqual(expected.serialized, value, "serialize: " + (c["note"] as! String))
        }
        for c in v["invalid"] as! [[String: Any]] {
            XCTAssertNil(StoredChoice.parse(c["value"] as! String), c["note"] as! String)
        }
    }

    func testReaskVectors() {
        let v = Kit.json("vectors/reask.json") as! [String: Any]
        let now = (v["now"] as! NSNumber).int64Value
        let cases = v["cases"] as! [[String: Any]]
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let cfg = c["config"] as! [String: Any]
            let purposes = (cfg["purposes"] as! [[String: Any]]).map {
                PurposeRef(key: $0["key"] as! String, required: $0["required"] as! Bool, rev: $0["rev"] as! Int)
            }
            let ask = Rules.reask(
                stored(c["stored"]), renewMonths: cfg["renew_months"] as! Int, banner: cfg["banner"] as! Int,
                abTestB: cfg["ab_test_b"] as? Int, purposes: purposes, now: now)
            XCTAssertEqual(ask != nil, c["ask"] as! Bool, c["name"] as! String)
        }
    }

    func testConsentModeVectors() {
        let v = Kit.json("vectors/consent-mode.json") as! [String: Any]
        let map = v["map"] as! [String: String]
        XCTAssertEqual(ConsentModeRules.order, v["order"] as! [String])
        XCTAssertEqual(ConsentModeRules.defaultMap, map)
        for c in v["cases"] as! [[String: Any]] {
            let choice = c["choice"] as? [String: Bool]
            let granted = choice.map { Set($0.filter { $0.value }.keys) }
            let signals = ConsentModeRules.signals(map: map, granted: granted)
            let expected = (c["signals"] as! [String: String]).mapValues { $0 == "granted" }
            XCTAssertEqual(signals, expected, c["name"] as! String)
            XCTAssertEqual(ConsentModeRules.grantedSignals(map: map, granted: granted ?? []), c["granted"] as! [String])
        }
    }

    func testGoldenConfigurationDecodes() throws {
        let c = try XCTUnwrap(AppConfig(data: Kit.data("bodies/config.json")))
        let (cfg, app) = try XCTUnwrap(c.usable)
        XCTAssertEqual(cfg.site, "ATMONA02")
        XCTAssertEqual(cfg.optional.map { $0.key }, ["analytics", "advertising"])
        XCTAssertEqual(cfg.ui.hero?.poster.count, 2)
        XCTAssertEqual(app.ids, ["fr.ateliermona.app", "fr.ateliermona.app.dev"])
        let off = try XCTUnwrap(AppConfig(data: Kit.data("bodies/config-off.json")))
        XCTAssertNil(off.usable)
        XCTAssertEqual(off.ttl, 300)
    }

    func testWordsMatchTheKit() throws {
        let dir = Kit.cmp.appendingPathComponent("words")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(files.count, Words.languages.count)
        for f in files {
            let lang = String(f.dropLast(5))
            let kit = Kit.json("words/" + f) as! [String: String]
            let w = try XCTUnwrap(Words.load(lang), lang)
            let mirror = Dictionary(uniqueKeysWithValues: Mirror(reflecting: w).children.map { ($0.label!, $0.value as! String) })
            XCTAssertEqual(mirror, kit, lang)
        }
        XCTAssertEqual(Words.of("fr-BE").next, "Suivant")
        XCTAssertEqual(Words.of("xx").next, "Next")
        XCTAssertEqual(SheetModel.stepOf(Words.of("de"), 2, 3), "Schritt 2 von 3")
    }

    func testLanguageNegotiation() {
        let enabled = ["fr", "en", "de", "nb", "pt", "zh"]
        let aliases = ["no": "nb", "nn": "nb"]
        func pick(_ p: [String]) -> String { Rules.pickLanguage(enabled: enabled, fallback: "fr", preferred: p, aliases: aliases) }
        XCTAssertEqual(pick(["de-CH", "fr"]), "de")
        XCTAssertEqual(pick(["pt-BR"]), "pt")
        XCTAssertEqual(pick(["zh-Hant-TW"]), "zh")
        XCTAssertEqual(pick(["nn-NO"]), "nb")
        XCTAssertEqual(pick(["no"]), "nb")
        XCTAssertEqual(pick(["ja", "it"]), "fr")
        XCTAssertEqual(pick(["en_GB"]), "en")
    }

    /// `cmp/src/shared/color.ts` on the same colours (values printed by the web's code).
    func testColoursMatchTheWeb() {
        let cases: [(String, String, String, String)] = [
            ("#1F6F5C", "#217763", "#FFFFFF", "#FFFFFF"), ("#B4441E", "#B4441E", "#FFFFFF", "#FFFFFF"),
            ("#17131F", "#FFFFFF", "#FFFFFF", "#17131F"), ("#000000", "#FFFFFF", "#FFFFFF", "#17131F"),
            ("#6B4EFF", "#6B4EFF", "#FFFFFF", "#FFFFFF"), ("#0B3D91", "#115FE2", "#FFFFFF", "#FFFFFF"),
            ("#FFD400", "#FFD400", "#17131F", "#17131F"), ("#2E2A3B", "#FFFFFF", "#FFFFFF", "#17131F"),
            ("#7A1F3D", "#BB305E", "#FFFFFF", "#FFFFFF"), ("#FFFFFF", "#FFFFFF", "#17131F", "#17131F"),
        ]
        for (c, dark, on, onDark) in cases {
            let rgb = RGB(hex: c)!
            XCTAssertEqual(rgb.darkBrand.hex, dark, c)
            XCTAssertEqual(rgb.onColor.hex, on, c)
            XCTAssertEqual(rgb.darkBrand.onColor.hex, onDark, c)
            let p = Palette.make(color: c, dark: true)
            XCTAssertGreaterThanOrEqual(p.brand.contrast(p.onBrand), 4.5, c)
        }
        XCTAssertTrue(Palette.make(color: "#FFD400", dark: false).brandEdge)
        XCTAssertFalse(Palette.make(color: "#1F6F5C", dark: false).brandEdge)
    }

    /// `cmp/src/ui/labels.ts` `frenchSpacing` on the same strings (values printed by the web's code).
    func testFrenchSpacingMatchesTheWeb() {
        let n = "\u{202F}"
        let cases = [
            ("Vos données : vos choix !", "Vos données\(n): vos choix\(n)!"), ("Bonjour!", "Bonjour\(n)!"),
            ("« Tout accepter »", "«\(n)Tout accepter\(n)»"), ("«Tout»", "«\(n)Tout\(n)»"), ("https://x.fr", "https://x.fr"),
            ("Il est 10:30 ici", "Il est 10:30 ici"), ("Quoi ?? Oui", "Quoi\(n)?? Oui"), ("Fin:", "Fin\(n):"),
            ("a ; b", "a\(n); b"), ("Vraiment !»", "Vraiment\(n)!\(n)»"),
        ]
        for (s, e) in cases { XCTAssertEqual(Typography.frenchSpacing(s), e, s) }
    }

    func testConsentIds() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let id = StoredChoice.newConsentId()
            XCTAssertTrue(StoredChoice.isConsentId(id), id)
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 200)
    }
}
