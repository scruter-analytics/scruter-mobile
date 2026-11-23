import Foundation
import XCTest

@testable import ScruterCMP

/// The IAB TCF (docs/CMP-MOBILE.md §6): every vector of `sdk/protocol/cmp/tcf-vectors.json` (generated from the site
/// script's code), then the engine with a TCF configuration: the keys written before the sheet closes and kept in step,
/// the proof's string, the re-ask of rule 5, `debugReset()`, the TCF turned off.
final class TCFTests: XCTestCase {
    private static let vectors = Kit.json("tcf-vectors.json") as! [String: Any]

    private func settings(_ j: Any?) -> TcfSettings { TcfSettings(json: j as! [String: Any])! }

    private func list(_ file: Any?) -> VendorList? { (file as? String).map { VendorList(data: Kit.data($0))! } }

    private func choice(_ j: Any?) -> TcfChoice? {
        guard let o = j as? [String: Any] else { return nil }
        let map: (String) -> [Int: Bool] = { k in
            var out = [Int: Bool]()
            for (key, v) in o[k] as? [String: Bool] ?? [:] { out[Int(key)!] = v }
            return out
        }
        var c = TcfChoice(vendors: map("vendors"), vendorsLi: map("vendorsLi"), purposesLi: map("purposesLi"), specialFeatures: map("specialFeatures"))
        if o["purposes"] != nil { c.purposes = map("purposes") }
        c.ac = map("ac")
        return c
    }

    private var purposes: [PurposeRef] {
        (TCFTests.vectors["purposes"] as! [[String: Any]]).map { PurposeRef(key: $0["key"] as! String, required: $0["required"] as! Bool, rev: 1) }
    }

    private func ints(_ v: Any?) -> [Int] { (v as? [NSNumber] ?? []).map { $0.intValue } }

    private func check(_ m: TcModel, _ e: [String: Any], _ name: String) {
        XCTAssertEqual(m.created, (e["created"] as! NSNumber).int64Value, name)
        XCTAssertEqual(m.updated, (e["updated"] as! NSNumber).int64Value, name)
        XCTAssertEqual([m.cmpId, m.cmpVersion, m.consentScreen, m.vendorListVersion, m.policyVersion],
                       ["cmpId", "cmpVersion", "consentScreen", "vendorListVersion", "policyVersion"].map { e[$0] as! Int }, name)
        XCTAssertEqual(m.consentLanguage, (e["consentLanguage"] as! String).uppercased(), name)
        XCTAssertEqual(m.publisherCC, e["publisherCC"] as? String, name)
        XCTAssertEqual(m.specialFeatureOptins, ints(e["specialFeatureOptins"]), name)
        XCTAssertEqual(m.purposeConsents, ints(e["purposeConsents"]), name)
        XCTAssertEqual(m.purposeLegitimateInterests, ints(e["purposeLegitimateInterests"]), name)
        XCTAssertEqual(m.vendorConsents, ints(e["vendorConsents"]), name)
        XCTAssertEqual(m.vendorLegitimateInterests, ints(e["vendorLegitimateInterests"]), name)
        XCTAssertEqual(m.vendorsDisclosed ?? [], ints(e["vendorsDisclosed"]), name)
        let r = (e["restrictions"] as! [[String: Any]]).map {
            TcRestriction(purpose: $0["purpose"] as! Int, type: $0["type"] as! Int, vendors: ints($0["vendors"]))
        }
        XCTAssertEqual(m.restrictions, r, name)
        let p = e["publisher"] as! [String: Any]
        XCTAssertEqual(m.publisherConsents ?? [], ints(p["consents"]), name)
        XCTAssertEqual(m.publisherLegitimateInterests, ints(p["legitimateInterests"]), name)
    }

    private func keysEqual(_ a: [String: Any], _ b: [String: Any], _ name: String) {
        XCTAssertEqual(Set(a.keys), Set(b.keys), name)
        for (k, v) in b {
            if let i = v as? NSNumber, !(v is String) {
                XCTAssertEqual(a[k] as? Int, i.intValue, name + ": " + k)
            } else {
                XCTAssertEqual(a[k] as? String, v as? String, name + ": " + k)
            }
        }
    }

    func testEveryVectorEncodesAsTheWeb() {
        let now = (TCFTests.vectors["now"] as! NSNumber).int64Value
        let cases = TCFTests.vectors["cases"] as! [[String: Any]]
        XCTAssertGreaterThan(cases.count, 15)
        for c in cases {
            let name = c["name"] as! String
            let t = settings(c["settings"])
            let m = TCF.build(
                t, list: list(c["vendor_list"]), bannerPurposes: purposes, lang: c["lang"] as! String, now: now,
                granted: Set((c["granted"] as! [String: Bool]).filter { $0.value }.keys), choice: choice(c["choice"]))
            check(m, c["model"] as! [String: Any], name)
            let tc = TCString.encode(m)
            XCTAssertEqual(tc, c["tc"] as? String, name)
            // Google's Additional Consent string, for a site with its other ad tech providers.
            let ac = TCF.ac(t, list: list(c["vendor_list"]), m, choice: choice(c["choice"])).map(TCF.acString)
            XCTAssertEqual(ac, c["ac"] as? String, name)
            if let a = ac { XCTAssertEqual(TCF.parseAc(a).map(TCF.acString), a, name) }
            keysEqual(TCF.keys(m, tc: tc, ac: ac), c["keys"] as! [String: Any], name)
            // Read back, the string gives the same model and keys (what the module writes again at a launch).
            let back = TCString.decode(tc)!
            check(back, c["model"] as! [String: Any], "decode: " + name)
            keysEqual(TCF.keys(back, tc: tc, ac: ac), c["keys"] as! [String: Any], "decode: " + name)
        }
    }

    func testTheReaskVectors() {
        for r in TCFTests.vectors["reask"] as! [[String: Any]] {
            XCTAssertEqual(
                TCF.mustAsk(
                    settings(r["settings"]), stored: r["stored"] as? String, list: list(r["vendor_list"]), storedAc: r["stored_ac"] as? String),
                r["ask"] as! Bool, r["name"] as! String)
        }
    }

    func testTheFirstLayerSaysWhatTheWebSays() {
        for c in TCFTests.vectors["cases"] as! [[String: Any]] {
            guard let f = c["first"] as? [String: Any], let l = list(c["vendor_list"]) else { continue }
            let name = c["name"] as! String
            let t = settings(c["settings"])
            let sheet = TcfSheet(
                settings: t, list: l, purposes: purposes, names: [:], words: Words.of("fr"), lang: "fr", stored: nil, renewMonths: 6)!
            XCTAssertEqual(Array(1...11).filter { sheet.consentPurposes.contains($0) || sheet.liPurposes.contains($0) }, ints(f["purposes"]), name)
            XCTAssertEqual(sheet.vendors.count + sheet.ac.count, f["partners"] as? Int, name)
            XCTAssertEqual(sheet.specialFeatures, ints(f["special_features"]), name)
            if let cover = f["cover"] as? [[String: Int]] {
                let shown = ints(f["purposes"])
                let mine = TcfSheet.cover(l.stacks, Array(shown.dropFirst()))
                XCTAssertEqual(mine, cover.map { $0["stack"] ?? -($0["purpose"] ?? 0) }, name)
                XCTAssertTrue(sheet.first.contains { $0.bold }, name)
            }
            if let fs = f["feature_stack"] as? Int { XCTAssertEqual(TcfSheet.featureStack(l.stacks, ints(f["special_features"])), fs, name) }
        }
    }

    func testDecodeRefusesWhatIsNotAVersion2String() {
        XCTAssertNil(TCString.decode("BOEFEAyOEFEAyAHABDENAI4AAAB9vABAASA"))
        XCTAssertNil(TCString.decode("not-a-tc-string"))
        XCTAssertNil(TCString.decode(""))
    }

    func testAdditionalConsentStrings() {
        XCTAssertEqual(TCF.parseAc("2~108.184~dv.2572"), AcData(consented: [108, 184], disclosed: [2572]))
        XCTAssertEqual(TCF.parseAc("2~~dv."), AcData(consented: [], disclosed: []))
        XCTAssertEqual(TCF.parseAc("2~1.2~dv"), AcData(consented: [1, 2], disclosed: []))
        XCTAssertEqual(TCF.parseAc("1~108.184"), AcData(consented: [108, 184], disclosed: []))
        for bad in ["", "2~108", "3~1~dv.2", "2~a~dv.", "2~1~dvx", "2~1~dv.2~3"] { XCTAssertNil(TCF.parseAc(bad), bad) }
        XCTAssertEqual(TCF.acString(AcData(consented: [2572, 108], disclosed: [])), "2~108.2572~dv.")
    }

    // MARK: The engine

    private func tcfConfig() -> Data { Kit.data("bodies/config-tcf.json") }

    func testTheKeysAreWrittenBeforeTheSheetClosesAndTheProofCarriesTheString() throws {
        let h = Harness()
        h.ingest.config = tcfConfig()
        let e = h.start()
        // A CMP is there and the GDPR applies before any choice.
        XCTAssertEqual(h.iab.values["IABTCF_CmpSdkID"] as? Int, 528)
        XCTAssertEqual(h.iab.values["IABTCF_gdprApplies"] as? Int, 1)
        XCTAssertEqual(h.iab.values["IABTCF_PolicyVersion"] as? Int, 5)
        XCTAssertNil(h.iab.values["IABTCF_TCString"])
        XCTAssertEqual(h.ingest.count("/cmp/ATMONA02/vendors-186.json"), 1)
        let model = try XCTUnwrap(h.host.shown.last)
        let sheet = try XCTUnwrap(model.tcf, "the TCF layers")
        XCTAssertEqual(sheet.vendors.count, 10)
        // Google's other ad tech providers of the golden configuration, by name; the first layer counts them.
        XCTAssertEqual(sheet.ac.map { $0.name }, ["AppLovin Corp.", "Booking.com", "eBay", "Snap Inc.", "Tradedoubler AB", "Unity Ads"])
        XCTAssertEqual(sheet.ac.first { $0.id == 486 }?.policyURL, "http://www.tradedoubler.com/en/privacy-policy/")
        XCTAssertEqual(sheet.list.purposes[1]?.name, "Stocker et/ou accéder à des informations sur un appareil")
        XCTAssertTrue(sheet.first.map { $0.text }.joined().hasPrefix("Nous et nos 16 partenaires"))
        XCTAssertEqual(e.snapshot.state, .needsDecision)
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        let accept = (TCFTests.vectors["cases"] as! [[String: Any]])[0]
        let tc = try XCTUnwrap(h.iab.values["IABTCF_TCString"] as? String)
        XCTAssertEqual(h.kept.values["tcf"] as? String, tc)
        let m = try XCTUnwrap(TCString.decode(tc))
        XCTAssertEqual(m.cmpId, 528)
        XCTAssertEqual(m.vendorConsents, ints((accept["model"] as! [String: Any])["vendorConsents"]))
        XCTAssertEqual(h.iab.values["IABTCF_PurposeConsents"] as? String, "10110000100")
        XCTAssertEqual(h.iab.values["IABTCF_SpecialFeaturesOptIns"] as? String, "11")
        // Google's Additional Consent string beside it, kept and sent with the proof after `~`.
        let ac = "2~108.184.486.1301.2572.3234~dv."
        XCTAssertEqual(h.iab.values["IABTCF_AddtlConsent"] as? String, ac)
        XCTAssertEqual(h.kept.values["tcfAc"] as? String, ac)
        let proof = try XCTUnwrap(h.ingest.bodies("/cmp/consent").last)
        XCTAssertEqual(proof["tc"] as? String, tc + "~" + ac)
        XCTAssertEqual(proof["gv"] as? Int, 186)
        Kit.record("cmp-consent", "tcf-accept-all", JSON.data(proof))

        // « Tout refuser » from the preferences: a withdrawal, nothing signalled any more.
        e.showPreferences(anchor: nil)
        h.decide(.rejectAll, granted: [], source: .preferences)
        XCTAssertEqual(h.iab.values["IABTCF_PurposeConsents"] as? String, "00000000000")
        XCTAssertEqual(h.iab.values["IABTCF_VendorConsents"] as? String, "")
        XCTAssertEqual(h.iab.values["IABTCF_PurposeLegitimateInterests"] as? String, "00000000000")
        XCTAssertEqual(h.iab.values["IABTCF_AddtlConsent"] as? String, "2~~dv.108.184.486.1301.2572.3234")
        XCTAssertEqual(h.ingest.bodies("/cmp/consent").last?["c"] as? String, "withdraw")
    }

    func testTheTCFLayersChoice() throws {
        let h = Harness()
        h.ingest.config = tcfConfig()
        h.start()
        let model = try XCTUnwrap(h.host.shown.last)
        h.engine.sheetDidAppear(model.kind)
        var c = TcfChoice()
        c.purposes = [3: false]
        c.vendors = [755: false]
        c.vendorsLi = [21: false]
        c.purposesLi = [7: false]
        c.specialFeatures = [1: true, 2: false]
        c.ac = [184: false]
        h.engine.decide(SheetDecision(action: nil, granted: ["analytics", "advertising"], source: .banner, tcf: c), model: model)
        // Purpose 3 refused: none of Google's providers consented, all disclosed.
        XCTAssertEqual(h.iab.values["IABTCF_AddtlConsent"] as? String, "2~~dv.108.184.486.1301.2572.3234")
        let vector = (TCFTests.vectors["cases"] as! [[String: Any]]).first { ($0["name"] as! String).hasPrefix("preferences: purpose 3 refused") }!
        let expected = vector["keys"] as! [String: Any]
        let m = try XCTUnwrap(TCString.decode(h.iab.values["IABTCF_TCString"] as! String))
        XCTAssertEqual(m.vendorConsents, ints((vector["model"] as! [String: Any])["vendorConsents"]))
        for k in ["IABTCF_PurposeConsents", "IABTCF_VendorConsents", "IABTCF_VendorLegitimateInterests", "IABTCF_SpecialFeaturesOptIns"] {
            XCTAssertEqual(h.iab.values[k] as? String, expected[k] as? String, k)
        }
        // The preferences start from the stored TCF choice.
        h.engine.showPreferences(anchor: nil)
        let prefs = try XCTUnwrap(h.host.shown.last?.tcf?.stored)
        XCTAssertEqual(prefs.vendors[755], false)
        XCTAssertEqual(prefs.vendorsLi[21], false)
        XCTAssertEqual(prefs.specialFeatures[1], true)
        XCTAssertEqual(prefs.ac[184], false)
    }

    func testAProviderOfGoogleTheStoredStringDidNotNameAsksAgain() throws {
        let h = Harness()
        let without3234 = config { c in
            c = Kit.json("bodies/config-tcf.json") as! [String: Any]
            editConfig(&c) { inner in
                var t = inner["tcf"] as! [String: Any]
                t["ac_providers"] = [108, 184, 486, 1301, 2572]
                inner["tcf"] = t
            }
        }
        h.ingest.config = without3234
        h.start()
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        XCTAssertEqual(h.iab.values["IABTCF_AddtlConsent"] as? String, "2~108.184.486.1301.2572~dv.")
        // The same selection: nothing asked.
        let h2 = h.relaunch()
        h2.ingest.config = without3234
        h2.start()
        XCTAssertEqual(h2.engine.snapshot.state, .ready)
        // 3234 added, on Google's list: asked again once the new configuration arrives.
        h2.ingest.config = config { c in
            c = Kit.json("bodies/config-tcf.json") as! [String: Any]
            editConfig(&c) { inner in inner["config_rev"] = 43 }
        }
        h2.scheduler.advance(3_600_000)
        h2.engine.willEnterForeground()
        XCTAssertEqual(h2.engine.snapshot.state, .needsDecision)
    }

    func testKeysKeptInStepAndAReaskOnANewPolicyOrAnAddedVendor() throws {
        let h = Harness()
        h.ingest.config = tcfConfig()
        h.start()
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        let tc = h.iab.values["IABTCF_TCString"] as! String
        let written = h.iab.iab
        // An app or a library removed the keys: the next launch writes them again from the stored string.
        let h2 = h.relaunch()
        h2.iab.values = [:]
        h2.start()
        XCTAssertEqual(h2.iab.values["IABTCF_TCString"] as? String, tc)
        XCTAssertEqual(Set(h2.iab.iab.keys), Set(written.keys))
        XCTAssertEqual(h2.iab.values["IABTCF_VendorConsents"] as? String, written["IABTCF_VendorConsents"] as? String)
        XCTAssertEqual(h2.engine.snapshot.state, .ready)

        // A new TCF policy: asked again; the previous answers hold until the new decision.
        h2.ingest.config = config { c in
            c = Kit.json("bodies/config-tcf.json") as! [String: Any]
            editConfig(&c) { inner in
                var t = inner["tcf"] as! [String: Any]
                t["policy_version"] = 6
                inner["tcf"] = t
                inner["config_rev"] = 43
            }
        }
        h2.scheduler.advance(3_600_000)
        h2.engine.willEnterForeground()
        XCTAssertEqual(h2.engine.snapshot.state, .needsDecision)
        XCTAssertEqual(h2.iab.values["IABTCF_PolicyVersion"] as? Int, 6)
        XCTAssertEqual(h2.iab.values["IABTCF_TCString"] as? String, tc, "kept until the new decision")
        h2.decide(.rejectAll, granted: [])
        XCTAssertEqual(TCString.decode(h2.iab.values["IABTCF_TCString"] as! String)?.policyVersion, 6)

        // The publisher selects a vendor of the list the string did not disclose (1500 is deleted: never).
        let h3 = h2.relaunch()
        h3.ingest.config = config { c in
            c = Kit.json("bodies/config-tcf.json") as! [String: Any]
            editConfig(&c) { inner in
                var t = inner["tcf"] as! [String: Any]
                t["policy_version"] = 6
                t["vendors"] = [10, 21, 32, 52, 76, 91, 132, 755, 793, 1126, 1500]
                t["vendors_url"] = "/cmp/ATMONA02/vendors-186.json?r=44"
                inner["tcf"] = t
            }
        }
        h3.start()
        XCTAssertEqual(h3.engine.snapshot.state, .ready, "a deleted vendor never asks again")
    }

    func testAnExpiredChoiceSignalsNothingDebugResetAndTheTCFTurnedOff() throws {
        let h = Harness()
        h.device.isDebugBuild = true
        h.ingest.config = tcfConfig()
        let e = h.start()
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        XCTAssertNotNil(h.iab.values["IABTCF_TCString"])
        // Six months later (the banner's period): no consent, no string, the header stays.
        h.scheduler.advance(Int64(7 * 31) * 86_400_000)
        e.willEnterForeground()
        XCTAssertEqual(e.snapshot.state, .needsDecision)
        XCTAssertNil(h.iab.values["IABTCF_TCString"])
        XCTAssertNil(h.iab.values["IABTCF_VendorConsents"])
        XCTAssertEqual(h.iab.values["IABTCF_CmpSdkID"] as? Int, 528)
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        XCTAssertNotNil(h.iab.values["IABTCF_TCString"])
        // debugReset() forgets the choice and its string; the header is written again for the configuration.
        e.debugReset()
        XCTAssertNil(h.iab.values["IABTCF_TCString"])
        XCTAssertNil(h.iab.values["IABTCF_AddtlConsent"])
        XCTAssertNil(h.kept.values["tcf"])
        XCTAssertEqual(h.iab.values["IABTCF_gdprApplies"] as? Int, 1)
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        // The site turns the TCF off: nothing of ours stays for vendors.
        h.ingest.config = Kit.data("bodies/config.json")
        h.scheduler.advance(3_600_000)
        e.willEnterForeground()
        XCTAssertTrue(h.iab.iab.isEmpty, "\(h.iab.iab.keys)")
        XCTAssertNil(h.kept.values["tcf"])
    }

    func testWithoutTheVendorListTheStandardLayersShowAndNothingIsDisclosed() throws {
        let h = Harness()
        h.ingest.config = tcfConfig()
        h.ingest.holdPaths = ["/vendors-"]
        h.start()
        XCTAssertTrue(h.host.shown.isEmpty, "the sheet waits for the vendor list")
        h.scheduler.advance(3_100)
        let model = try XCTUnwrap(h.host.shown.last)
        XCTAssertNil(model.tcf)
        h.decide(.acceptAll, granted: ["analytics", "advertising"])
        let m = try XCTUnwrap(TCString.decode(h.iab.values["IABTCF_TCString"] as! String))
        XCTAssertEqual(m.vendorsDisclosed, [])
        XCTAssertEqual(m.vendorConsents, [])
    }
}
