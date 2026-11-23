import Foundation

// The IAB TCF v2.2 in the app (docs/CMP-MOBILE.md §6): the site's TCF settings, the vendor list, the TC model of a
// decision, the TC string, Google's Additional Consent string and the in-app keys. A port of the site script's
// `cmp/src/tcf/model.ts` and `tcstring.ts`, checked against the kit's `tcf-vectors.json`, which is generated from them.

/// `config.tcf`: the site's TCF settings, which apply to its app.
final class TcfSettings {
    var cmpId: Int
    var cmpVersion: Int
    var gvlVersion: Int
    var policyVersion: Int
    var publisherCC: String
    var vendors: [Int]
    /// IAB purpose → `consent`, `legitimate_interest` or `off`.
    var purposes: [Int: String]
    var specialFeatures: [Int]
    /// IAB purpose → the banner purpose it is grouped under.
    var stacks: [Int: String]
    var vendorsURL: String
    var translationsURL: String
    /// Google's other ad tech providers (ids of its Additional Consent list), shown after the vendors.
    var acProviders: [Int]

    @_optimize(size) init?(json j: JSONObject) {
        guard let id = j.int("cmp_id"), let gvl = j.int("gvl_version"), let pv = j.int("policy_version") else { return nil }
        cmpId = id
        cmpVersion = j.int("cmp_version") ?? 1
        gvlVersion = gvl
        policyVersion = pv
        publisherCC = j.str("publisher_cc") ?? "FR"
        vendors = (j["vendors"] as? [NSNumber] ?? []).map { $0.intValue }
        purposes = TcfSettings.byId(j.obj("purposes"))
        specialFeatures = (j["special_features"] as? [NSNumber] ?? []).map { $0.intValue }
        stacks = TcfSettings.byId(j.obj("stacks"))
        vendorsURL = j.str("vendors_url") ?? ""
        translationsURL = j.str("translations_url") ?? "/cmp/tcf/\(gvl)/{lang}.json"
        acProviders = (j["ac_providers"] as? [NSNumber] ?? []).map { $0.intValue }
    }

    @_optimize(size) private static func byId(_ o: JSONObject?) -> [Int: String] {
        var out = [Int: String]()
        for (k, v) in o ?? [:] { if let id = Int(k), let s = v as? String { out[id] = s } }
        return out
    }

    /// The publisher's legal basis of IAB purpose `p` (purposes 1 and 3–6 rest on consent only).
    @_optimize(size) func basis(_ p: Int) -> String {
        let b = purposes[p] ?? "off"
        return b == "legitimate_interest" && [1, 3, 4, 5, 6].contains(p) ? "off" : b
    }

    var cc: String {
        let c = publisherCC.uppercased()
        return c.count == 2 && c.unicodeScalars.allSatisfy { $0.value >= 65 && $0.value <= 90 } ? c : "FR"
    }
}

/// One vendor of the GVL as the vendor subset serves it.
final class GvlVendor {
    var id: Int
    var name: String
    var purposes: [Int]
    var legIntPurposes: [Int]
    var flexiblePurposes: [Int]
    var specialPurposes: [Int]
    var features: [Int]
    var specialFeatures: [Int]
    var dataDeclaration: [Int]
    var policyURL: String?
    var urls: [JSONObject]
    var cookieMaxAgeSeconds: Int?
    var usesCookies: Bool
    var cookieRefresh: Bool
    var usesNonCookieAccess: Bool
    var deviceStorageDisclosureURL: String?
    var stdRetention: Int?
    var retention: [Int: Int]
    var retentionSp: [Int: Int]
    var deleted: Bool

    @_optimize(size) init?(json j: JSONObject) {
        guard let id = j.int("id") else { return nil }
        let ids: (String) -> [Int] = { (j[$0] as? [NSNumber] ?? []).map { $0.intValue } }
        self.id = id
        name = j.str("name")?.trimmingCharacters(in: .whitespaces) ?? "#\(id)"
        purposes = ids("purposes")
        legIntPurposes = ids("legIntPurposes")
        flexiblePurposes = ids("flexiblePurposes")
        specialPurposes = ids("specialPurposes")
        features = ids("features")
        specialFeatures = ids("specialFeatures")
        dataDeclaration = ids("dataDeclaration")
        policyURL = j.str("policyUrl")
        urls = j.objs("urls") ?? []
        cookieMaxAgeSeconds = j.int("cookieMaxAgeSeconds")
        usesCookies = j.bool("usesCookies") ?? false
        cookieRefresh = j.bool("cookieRefresh") ?? false
        usesNonCookieAccess = j.bool("usesNonCookieAccess") ?? false
        deviceStorageDisclosureURL = j.str("deviceStorageDisclosureUrl")
        let r = j.obj("dataRetention")
        stdRetention = r?.int("stdRetention")
        let days: (String) -> [Int: Int] = { k in
            var out = [Int: Int]()
            for (key, v) in r?.obj(k) ?? [:] { if let p = Int(key), let n = (v as? NSNumber)?.intValue { out[p] = n } }
            return out
        }
        retention = days("purposes")
        retentionSp = days("specialPurposes")
        deleted = j["deletedDate"] is String
    }

    /// The vendor's privacy policy or legitimate interest claim in `lang`, else English, else the first.
    @_optimize(size) func url(_ key: String, lang: String) -> String? {
        let l = String(lang.lowercased().prefix(2))
        let u = urls.first { ($0.str("langId") ?? "").lowercased() == l } ?? urls.first { $0.str("langId") == "en" } ?? urls.first
        let v = u?.str(key) ?? (key == "privacy" ? policyURL : nil)
        return v.flatMap { $0.hasPrefix("https://") ? $0 : nil }
    }
}

/// An IAB text: a purpose, special purpose, feature, special feature, data category or stack.
struct TcfText {
    var name: String
    var description: String
    var illustrations: [String]
    var purposes: [Int]
    var specialFeatures: [Int]
}

/// One of Google's other ad tech providers (its Additional Consent list gives a name and a privacy policy, no more).
final class AcProvider {
    let id: Int
    let name: String
    /// http or https, as Google lists it.
    let policyURL: String?

    @_optimize(size) init?(json j: JSONObject) {
        guard let id = j.int("id"), let name = j.str("name") else { return nil }
        self.id = id
        self.name = name
        policyURL = j.str("policyUrl").flatMap { $0.hasPrefix("https://") || $0.hasPrefix("http://") ? $0 : nil }
    }
}

/// `GET /cmp/{code}/vendors-{gvl}.json` (the vendor subset of the site's selection), and the texts of
/// `GET /cmp/tcf/{gvl}/{lang}.json` laid over it.
final class VendorList {
    var vendors: [Int: GvlVendor]
    /// Google's other ad tech providers of the selection still on Google's list.
    var acProviders: [Int: AcProvider]
    var purposes: [Int: TcfText]
    var specialPurposes: [Int: TcfText]
    var features: [Int: TcfText]
    var specialFeatures: [Int: TcfText]
    var dataCategories: [Int: TcfText]
    var stacks: [Int: TcfText]
    var featuresText: String?

    @_optimize(size) init?(json j: JSONObject) {
        guard let vs = j.obj("vendors") else { return nil }
        var map = [Int: GvlVendor]()
        for (_, v) in vs { if let o = v as? JSONObject, let g = GvlVendor(json: o) { map[g.id] = g } }
        vendors = map
        var ac = [Int: AcProvider]()
        for (_, v) in j.obj("acProviders") ?? [:] { if let o = v as? JSONObject, let a = AcProvider(json: o) { ac[a.id] = a } }
        acProviders = ac
        purposes = VendorList.texts(j.obj("purposes"))
        specialPurposes = VendorList.texts(j.obj("specialPurposes"))
        features = VendorList.texts(j.obj("features"))
        specialFeatures = VendorList.texts(j.obj("specialFeatures"))
        dataCategories = VendorList.texts(j.obj("dataCategories"))
        stacks = VendorList.texts(j.obj("stacks"))
        featuresText = j.obj("standardTexts")?.str("features")
    }

    @_optimize(size) convenience init?(data: Data) {
        guard let j = JSON.object(data) else { return nil }
        self.init(json: j)
    }

    /// A copy whose texts one language lays over.
    @_optimize(size) init(copy o: VendorList) {
        vendors = o.vendors
        acProviders = o.acProviders
        purposes = o.purposes
        specialPurposes = o.specialPurposes
        features = o.features
        specialFeatures = o.specialFeatures
        dataCategories = o.dataCategories
        stacks = o.stacks
        featuresText = o.featuresText
    }

    @_optimize(size) static func texts(_ o: JSONObject?) -> [Int: TcfText] {
        var out = [Int: TcfText]()
        for (k, v) in o ?? [:] {
            guard let id = Int(k), let t = v as? JSONObject else { continue }
            out[id] = TcfText(
                name: t.str("name") ?? "#\(id)", description: t.str("description") ?? "",
                illustrations: t.strs("illustrations") ?? [], purposes: (t["purposes"] as? [NSNumber] ?? []).map { $0.intValue },
                specialFeatures: (t["specialFeatures"] as? [NSNumber] ?? []).map { $0.intValue })
        }
        return out
    }

    /// IAB's translation of the texts (the stacks keep what they gather, from the vendor list); an English vendor list's
    /// standard texts only for English.
    @_optimize(size) func translated(_ j: JSONObject?, lang: String) {
        let en = lang.lowercased().hasPrefix("en")
        if !en { featuresText = nil }
        guard let j = j else { return }
        @_optimize(size) func lay(_ key: String, _ into: inout [Int: TcfText]) {
            for (id, t) in VendorList.texts(j.obj(key)) {
                if var cur = into[id] {
                    cur.name = t.name
                    cur.description = t.description
                    if !t.illustrations.isEmpty || key != "stacks" { cur.illustrations = t.illustrations }
                    into[id] = cur
                } else if key != "stacks" {
                    into[id] = t
                }
            }
        }
        lay("purposes", &purposes)
        lay("specialPurposes", &specialPurposes)
        lay("features", &features)
        lay("specialFeatures", &specialFeatures)
        lay("dataCategories", &dataCategories)
        lay("stacks", &stacks)
        if let f = j.obj("standardTexts")?.str("features") { featuresText = f }
    }

    /// A selected vendor of the list, unless the GVL deleted it (its signals stay 0).
    @_optimize(size) func live(_ id: Int) -> GvlVendor? {
        guard let v = vendors[id], !v.deleted else { return nil }
        return v
    }

    /// The site's selected providers of Google's list found in the vendor list, by id.
    @_optimize(size) func liveAc(_ t: TcfSettings) -> [AcProvider] {
        t.acProviders.compactMap { acProviders[$0] }.sorted { $0.id < $1.id }
    }
}

/// What Google's Additional Consent string says: the providers consented, then those only disclosed.
struct AcData: Equatable {
    var consented: [Int]
    var disclosed: [Int]
}

/// What the visitor chose in the TCF layers (`TcfChoice` of the site script): absent entries follow the banner purposes.
struct TcfChoice: Equatable {
    var vendors: [Int: Bool] = [:]
    /// Legitimate interest kept (false: the visitor objected).
    var vendorsLi: [Int: Bool] = [:]
    var purposesLi: [Int: Bool] = [:]
    var specialFeatures: [Int: Bool] = [:]
    /// IAB purposes on consent the visitor set one by one.
    var purposes: [Int: Bool]?
    /// Google's other ad tech providers; absent ones follow IAB purposes 1, 3 and 4.
    var ac: [Int: Bool] = [:]
}

/// A publisher restriction: purpose, type (0 not allowed, 1 require consent, 2 require legitimate interest), vendors.
struct TcRestriction: Equatable {
    var purpose: Int
    var type: Int
    var vendors: [Int]
}

/// The fields of a TC string (core segment, disclosed vendors, publisher TC).
final class TcModel {
    var created: Int64 = 0
    var updated: Int64 = 0
    var cmpId = 0
    var cmpVersion = 0
    var consentScreen = 1
    var consentLanguage = "EN"
    var vendorListVersion = 0
    var policyVersion = 0
    var isServiceSpecific = true
    var useNonStandardTexts = false
    var specialFeatureOptins: [Int] = []
    var purposeConsents: [Int] = []
    var purposeLegitimateInterests: [Int] = []
    var purposeOneTreatment = false
    var publisherCC = "FR"
    var vendorConsents: [Int] = []
    var vendorLegitimateInterests: [Int] = []
    var restrictions: [TcRestriction] = []
    var vendorsDisclosed: [Int]?
    var publisherConsents: [Int]?
    var publisherLegitimateInterests: [Int] = []
}

enum TCF {
    static let purposes = 11
    static let specialFeatures = 2
    /// IAB purposes an Additional Consent stands for (storage on the device, profiles and personalised ads).
    static let acPurposes = [1, 3, 4]

    /// The vendor's purposes resting on `b` under the publisher's settings (its declarations, flexible ones included).
    @_optimize(size) static func vendorPurposes(_ t: TcfSettings, _ v: GvlVendor, _ b: String) -> [Int] {
        let (own, other) = b == "consent" ? (v.purposes, v.legIntPurposes) : (v.legIntPurposes, v.purposes)
        return (1...purposes).filter { p in
            t.basis(p) == b && (own.contains(p) || (v.flexiblePurposes.contains(p) && other.contains(p)))
        }
    }

    /// The TC model of a decision (`buildModel` of the site script): `granted` the banner purposes, `choice` the TCF
    /// layers' switches (nil: everything follows the banner purposes), `now` in milliseconds.
    @_optimize(size) static func build(
        _ t: TcfSettings, list: VendorList?, bannerPurposes: [PurposeRef], lang: String, now: Int64, granted: Set<String>,
        choice: TcfChoice?
    ) -> TcModel {
        let optional = bannerPurposes.filter { !$0.required }
        let allGranted = optional.allSatisfy { granted.contains($0.key) }
        let noneGranted = !optional.contains { granted.contains($0.key) }
        let purposeGranted: (Int) -> Bool = { p in t.stacks[p].map { granted.contains($0) } ?? allGranted }
        let set = choice?.purposes
        let listed = t.vendors.compactMap { list?.live($0) }
        // Google's providers rest on consent for purposes 1, 3 and 4.
        let ac = !(list?.liveAc(t).isEmpty ?? true)
        let shown: (String, Int) -> Bool = { b, p in
            listed.contains { vendorPurposes(t, $0, b).contains(p) } || (ac && b == "consent" && acPurposes.contains(p))
        }
        let pc = (1...purposes).filter { p in
            t.basis(p) == "consent" && shown("consent", p) && (set?[p] ?? purposeGranted(p))
        }
        let pli = (1...purposes).filter { p in
            t.basis(p) == "legitimate_interest" && shown("legitimate_interest", p)
                && (choice.map { $0.purposesLi[p] != false } ?? !noneGranted)
        }
        let sf = t.specialFeatures.filter { f in
            listed.contains { $0.specialFeatures.contains(f) } && (choice.map { $0.specialFeatures[f] == true } ?? allGranted)
        }
        var vc = [Int](), vli = [Int](), disclosed = [Int]()
        var restrictions = [TcRestriction]()
        @_optimize(size) func restrict(_ p: Int, _ type: Int, _ id: Int) {
            if let i = restrictions.firstIndex(where: { $0.purpose == p && $0.type == type }) {
                restrictions[i].vendors.append(id)
            } else {
                restrictions.append(TcRestriction(purpose: p, type: type, vendors: [id]))
            }
        }
        for id in t.vendors {
            guard let v = list?.live(id) else { continue }
            disclosed.append(id)
            let cp = vendorPurposes(t, v, "consent")
            let lp = vendorPurposes(t, v, "legitimate_interest")
            let derived = !cp.isEmpty && cp.allSatisfy { pc.contains($0) }
            if !cp.isEmpty && (choice?.vendors[id] ?? derived) { vc.append(id) }
            let liDerived = lp.contains { pli.contains($0) }
            if !lp.isEmpty && (choice?.vendorsLi[id] ?? liDerived) { vli.append(id) }
            for p in 1...purposes where v.purposes.contains(p) || v.legIntPurposes.contains(p) {
                let b = t.basis(p)
                if b == "off" {
                    restrict(p, 0, id)
                } else if v.flexiblePurposes.contains(p) {
                    if b == "consent" && v.legIntPurposes.contains(p) { restrict(p, 1, id) }
                    if b == "legitimate_interest" && v.purposes.contains(p) { restrict(p, 2, id) }
                }
            }
        }
        let m = TcModel()
        let day = TCString.day(now)
        m.created = day
        m.updated = day
        m.cmpId = t.cmpId
        m.cmpVersion = t.cmpVersion
        let l = lang.unicodeScalars.prefix(2)
        m.consentLanguage = l.count == 2 && l.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII })
            ? String(String.UnicodeScalarView(l)).uppercased() : "EN"
        m.vendorListVersion = t.gvlVersion
        m.policyVersion = t.policyVersion
        m.specialFeatureOptins = sf
        m.purposeConsents = pc
        m.purposeLegitimateInterests = pli
        m.publisherCC = t.cc
        m.vendorConsents = vc
        m.vendorLegitimateInterests = vli
        // The restrictions in the order the site script finds them: by vendor, then by purpose.
        m.restrictions = restrictions
        m.vendorsDisclosed = disclosed
        m.publisherConsents = pc
        m.publisherLegitimateInterests = pli
        return m
    }

    /// The Additional Consent of a decision (`m` its TC model), or nil for a site without Google's other ad tech
    /// providers: every selected provider of the vendor list disclosed, consented when purposes 1, 3 and 4 are and the
    /// visitor did not refuse it (`buildAc` of the site script).
    @_optimize(size) static func ac(_ t: TcfSettings, list: VendorList?, _ m: TcModel, choice: TcfChoice?) -> AcData? {
        guard !t.acProviders.isEmpty else { return nil }
        let personal = acPurposes.allSatisfy { m.purposeConsents.contains($0) }
        var out = AcData(consented: [], disclosed: [])
        for a in list?.liveAc(t) ?? [] {
            if personal && choice?.ac[a.id] != false { out.consented.append(a.id) } else { out.disclosed.append(a.id) }
        }
        return out
    }

    /// Google's Additional Consent string v2: `2~<consented>~dv.<only disclosed>`, ids ascending.
    @_optimize(size) static func acString(_ a: AcData) -> String {
        let up: ([Int]) -> String = { $0.sorted().map(String.init).joined(separator: ".") }
        return "2~" + up(a.consented) + "~dv." + up(a.disclosed)
    }

    /// A stored Additional Consent string (version 2, or 1: consents only), else nil.
    @_optimize(size) static func parseAc(_ s: String) -> AcData? {
        let parts = s.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        let ids: (String) -> [Int]? = { x in
            let p = x.split(separator: ".").map { Int($0) }
            return p.contains(nil) ? nil : p.compactMap { $0 }
        }
        if parts.count == 2, parts[0] == "1", let c = ids(parts[1]) { return AcData(consented: c, disclosed: []) }
        guard parts.count == 3, parts[0] == "2", parts[2].hasPrefix("dv"), let c = ids(parts[1]) else { return nil }
        let d = parts[2].dropFirst(2)
        guard d.isEmpty || d.hasPrefix("."), let dv = ids(String(d.dropFirst(d.isEmpty ? 0 : 1))) else { return nil }
        return AcData(consented: c, disclosed: dv)
    }

    /// What the TCF layers show of a stored model (the visitor's previous TCF choice; `ac` its Additional Consent).
    @_optimize(size) static func choice(_ t: TcfSettings, _ m: TcModel, ac: AcData? = nil) -> TcfChoice {
        var c = TcfChoice()
        c.purposes = [:]
        for id in t.vendors {
            c.vendors[id] = m.vendorConsents.contains(id)
            c.vendorsLi[id] = m.vendorLegitimateInterests.contains(id)
        }
        for p in 1...purposes {
            if t.basis(p) == "legitimate_interest" { c.purposesLi[p] = m.purposeLegitimateInterests.contains(p) }
            if t.basis(p) == "consent" { c.purposes?[p] = m.purposeConsents.contains(p) }
        }
        for f in t.specialFeatures { c.specialFeatures[f] = m.specialFeatureOptins.contains(f) }
        if let a = ac { for id in t.acProviders { c.ac[id] = a.consented.contains(id) } }
        return c
    }

    /// docs/CMP.md §4.4 rule 5: no or an unreadable string, another CMP id or policy, a selected vendor of the vendor
    /// list (when it could be read) that the string did not disclose, or one of Google's providers of the list that the
    /// stored Additional Consent string does not name.
    @_optimize(size) static func mustAsk(_ t: TcfSettings, stored: String?, list: VendorList?, storedAc: String? = nil) -> Bool {
        guard let s = stored, let m = TCString.decode(s), m.cmpId == t.cmpId, m.policyVersion == t.policyVersion else {
            return true
        }
        let disclosed = m.vendorsDisclosed ?? []
        let a = storedAc.flatMap(parseAc)
        let named = (a?.consented ?? []) + (a?.disclosed ?? [])
        return t.vendors.contains { !disclosed.contains($0) && list?.live($0) != nil }
            || t.acProviders.contains { !named.contains($0) && list?.acProviders[$0] != nil }
    }

    /// The in-app keys of a decision (IAB CMP API v2.2, « In-App Details »; `ac`: Google's Additional Consent string,
    /// « In-app » of its specification): `Int` or `String` values.
    @_optimize(size) static func keys(_ m: TcModel, tc: String, ac: String? = nil) -> [String: Any] {
        @_optimize(size) func bits(_ ids: [Int], _ n: Int? = nil) -> String {
            let len = n ?? (ids.max() ?? 0)
            var s = ""
            for i in stride(from: 1, through: len, by: 1) { s.append(ids.contains(i) ? "1" : "0") }
            return s
        }
        var k: [String: Any] = [
            "IABTCF_CmpSdkID": m.cmpId, "IABTCF_CmpSdkVersion": m.cmpVersion, "IABTCF_PolicyVersion": m.policyVersion,
            "IABTCF_gdprApplies": 1, "IABTCF_PublisherCC": m.publisherCC,
            "IABTCF_PurposeOneTreatment": m.purposeOneTreatment ? 1 : 0, "IABTCF_UseNonStandardTexts": m.useNonStandardTexts ? 1 : 0,
            "IABTCF_TCString": tc, "IABTCF_VendorConsents": bits(m.vendorConsents),
            "IABTCF_VendorLegitimateInterests": bits(m.vendorLegitimateInterests),
            "IABTCF_DisclosedVendors": bits(m.vendorsDisclosed ?? []), "IABTCF_PurposeConsents": bits(m.purposeConsents, purposes),
            "IABTCF_PurposeLegitimateInterests": bits(m.purposeLegitimateInterests, purposes),
            "IABTCF_SpecialFeaturesOptIns": bits(m.specialFeatureOptins, specialFeatures),
            "IABTCF_PublisherConsent": bits(m.publisherConsents ?? [], purposes),
            "IABTCF_PublisherLegitimateInterests": bits(m.publisherLegitimateInterests, purposes),
            "IABTCF_PublisherCustomPurposesConsents": "", "IABTCF_PublisherCustomPurposesLegitimateInterests": "",
        ]
        for p in 1...purposes {
            var types = [Int: Int]()
            for r in m.restrictions where r.purpose == p { for v in r.vendors { types[v] = r.type } }
            guard let max = types.keys.max() else { continue }
            var s = ""
            for i in 1...max { s.append(types[i].map(String.init) ?? "_") }
            k["IABTCF_PublisherRestrictions\(p)"] = s
        }
        if let a = ac { k["IABTCF_AddtlConsent"] = a }
        return k
    }

    /// Every key this module writes (removed on `debugReset()` and when the site turns the TCF off).
    static var allKeys: [String] {
        [
            "IABTCF_CmpSdkID", "IABTCF_CmpSdkVersion", "IABTCF_PolicyVersion", "IABTCF_gdprApplies", "IABTCF_PublisherCC",
            "IABTCF_PurposeOneTreatment", "IABTCF_UseNonStandardTexts",
        ] + decisionKeys
    }

    /// The keys of a decision (removed when it no longer holds).
    static var decisionKeys: [String] {
        [
            "IABTCF_TCString", "IABTCF_VendorConsents", "IABTCF_VendorLegitimateInterests", "IABTCF_DisclosedVendors",
            "IABTCF_PurposeConsents", "IABTCF_PurposeLegitimateInterests", "IABTCF_SpecialFeaturesOptIns",
            "IABTCF_PublisherConsent", "IABTCF_PublisherLegitimateInterests", "IABTCF_PublisherCustomPurposesConsents",
            "IABTCF_PublisherCustomPurposesLegitimateInterests", "IABTCF_AddtlConsent",
        ] + (1...purposes).map { "IABTCF_PublisherRestrictions\($0)" }
    }
}

/// The TC string v2 (IAB « Consent string and vendor list formats »): core segment, disclosed vendors (type 1) and
/// publisher TC (type 3), base64url without padding, each segment's bits padded to a multiple of 24.
enum TCString {
    private static let dict = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// Deciseconds of `now`'s UTC day at 00:00 (TCF v2.2: created and updated at the day).
    @_optimize(size) static func day(_ now: Int64) -> Int64 { (now / 86_400_000) * 864_000 }

    struct Bits {
        var b: [Bool] = []

        @_optimize(size) mutating func int(_ v: Int64, _ n: Int) {
            for i in stride(from: n - 1, through: 0, by: -1) { b.append((v >> Int64(i)) & 1 == 1) }
        }

        @_optimize(size) mutating func int(_ v: Int, _ n: Int) { int(Int64(v), n) }

        @_optimize(size) mutating func bool(_ v: Bool) { b.append(v) }

        @_optimize(size) mutating func field(_ ids: [Int], _ n: Int) {
            if n > 0 { for i in 1...n { b.append(ids.contains(i)) } }
        }

        @_optimize(size) mutating func letters(_ s: String) {
            for u in s.uppercased().unicodeScalars.prefix(2) { int(max(0, Int(u.value) - 65), 6) }
        }

        @_optimize(size) mutating func ranges(_ ids: [Int]) {
            let r = TCString.runs(ids)
            int(r.count, 12)
            for (a, z) in r {
                bool(a != z)
                int(a, 16)
                if a != z { int(z, 16) }
            }
        }

        /// MaxVendorId, then a bit field or ranges, whichever is shorter (the IAB reference library's rule).
        @_optimize(size) mutating func vendors(_ set: [Int]) {
            let ids = Array(Set(set.filter { $0 > 0 })).sorted()
            let maxId = ids.last ?? 0
            let rangeLength = 12 + TCString.runs(ids).reduce(0) { $0 + ($1.0 == $1.1 ? 17 : 33) }
            int(maxId, 16)
            if maxId > 45 && rangeLength < maxId {
                bool(true)
                ranges(ids)
            } else {
                bool(false)
                field(ids, maxId)
            }
        }

        @_optimize(size) func base64() -> String {
            var bits = b
            while bits.count % 24 != 0 { bits.append(false) }
            var out = [UInt8]()
            var i = 0
            while i < bits.count {
                var v = 0
                for k in 0..<6 { v = v << 1 | (bits[i + k] ? 1 : 0) }
                out.append(TCString.dict[v])
                i += 6
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    @_optimize(size) static func runs(_ ids: [Int]) -> [(Int, Int)] {
        var out = [(Int, Int)]()
        for id in ids {
            if let last = out.last, last.1 == id - 1 { out[out.count - 1].1 = id } else { out.append((id, id)) }
        }
        return out
    }

    @_optimize(size) static func encode(_ m: TcModel) -> String {
        var c = Bits()
        c.int(2, 6)
        c.int(m.created, 36)
        c.int(m.updated, 36)
        c.int(m.cmpId, 12)
        c.int(m.cmpVersion, 12)
        c.int(m.consentScreen, 6)
        c.letters(m.consentLanguage)
        c.int(m.vendorListVersion, 12)
        c.int(m.policyVersion, 6)
        c.bool(m.isServiceSpecific)
        c.bool(m.useNonStandardTexts)
        c.field(m.specialFeatureOptins, 12)
        c.field(m.purposeConsents, 24)
        c.field(m.purposeLegitimateInterests, 24)
        c.bool(m.purposeOneTreatment)
        c.letters(m.publisherCC)
        c.vendors(m.vendorConsents)
        c.vendors(m.vendorLegitimateInterests)
        c.int(m.restrictions.count, 12)
        for r in m.restrictions {
            c.int(r.purpose, 6)
            c.int(r.type, 2)
            c.ranges(Array(Set(r.vendors.filter { $0 > 0 })).sorted())
        }
        var parts = [c.base64()]
        if let d = m.vendorsDisclosed {
            var s = Bits()
            s.int(1, 3)
            s.vendors(d)
            parts.append(s.base64())
        }
        if let pc = m.publisherConsents {
            var s = Bits()
            s.int(3, 3)
            s.field(pc, 24)
            s.field(m.publisherLegitimateInterests, 24)
            s.int(0, 6)
            parts.append(s.base64())
        }
        return parts.joined(separator: ".")
    }

    struct Reader {
        var b: [Bool]
        var i = 0

        @_optimize(size) mutating func int(_ n: Int) -> Int64? {
            guard i + n <= b.count else { return nil }
            var v: Int64 = 0
            for k in 0..<n { v = v << 1 | (b[i + k] ? 1 : 0) }
            i += n
            return v
        }

        @_optimize(size) mutating func small(_ n: Int) -> Int? { int(n).map { Int($0) } }

        @_optimize(size) mutating func field(_ n: Int) -> [Int]? {
            guard i + n <= b.count else { return nil }
            var out = [Int]()
            for k in 0..<n where b[i + k] { out.append(k + 1) }
            i += n
            return out
        }

        @_optimize(size) mutating func letters() -> String? {
            guard let a = small(6), let z = small(6), let x = UnicodeScalar(65 + a), let y = UnicodeScalar(65 + z) else { return nil }
            return String(Character(x)) + String(Character(y))
        }

        @_optimize(size) mutating func ranges() -> [Int]? {
            guard let n = small(12) else { return nil }
            var out = [Int]()
            for _ in 0..<n {
                guard let isRange = small(1), let a = small(16), let z = isRange == 1 ? small(16) : a, z >= a else { return nil }
                out += Array(a...z)
            }
            return out
        }

        @_optimize(size) mutating func vendors() -> [Int]? {
            guard let maxId = small(16), let isRange = small(1) else { return nil }
            return isRange == 1 ? ranges() : field(maxId)
        }
    }

    @_optimize(size) static func bits(_ segment: Substring) -> [Bool]? {
        var out = [Bool]()
        for u in segment.utf8 {
            guard let v = dict.firstIndex(of: u) else { return nil }
            for k in stride(from: 5, through: 0, by: -1) { out.append((v >> k) & 1 == 1) }
        }
        return out
    }

    /// A v2 TC string's fields, or nil.
    @_optimize(size) static func decode(_ tc: String) -> TcModel? {
        let segments = tc.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = segments.first, let b = bits(first) else { return nil }
        var r = Reader(b: b)
        let m = TcModel()
        guard r.small(6) == 2, let created = r.int(36), let updated = r.int(36), let cmpId = r.small(12),
            let cmpVersion = r.small(12), let screen = r.small(6), let lang = r.letters(), let gvl = r.small(12),
            let policy = r.small(6), let ss = r.small(1), let nst = r.small(1), let sf = r.field(12), let pc = r.field(24),
            let pli = r.field(24), let p1 = r.small(1), let cc = r.letters(), let vc = r.vendors(), let vli = r.vendors(),
            let n = r.small(12)
        else { return nil }
        m.created = created
        m.updated = updated
        m.cmpId = cmpId
        m.cmpVersion = cmpVersion
        m.consentScreen = screen
        m.consentLanguage = lang
        m.vendorListVersion = gvl
        m.policyVersion = policy
        m.isServiceSpecific = ss == 1
        m.useNonStandardTexts = nst == 1
        m.specialFeatureOptins = sf
        m.purposeConsents = pc
        m.purposeLegitimateInterests = pli
        m.purposeOneTreatment = p1 == 1
        m.publisherCC = cc
        m.vendorConsents = vc
        m.vendorLegitimateInterests = vli
        for _ in 0..<n {
            guard let p = r.small(6), let t = r.small(2), let vs = r.ranges() else { return nil }
            m.restrictions.append(TcRestriction(purpose: p, type: t, vendors: vs))
        }
        for seg in segments.dropFirst() {
            guard let sb = bits(seg) else { return nil }
            var s = Reader(b: sb)
            let type = s.small(3)
            if type == 1 {
                m.vendorsDisclosed = s.vendors()
            } else if type == 3 {
                guard let c = s.field(24), let l = s.field(24) else { return nil }
                m.publisherConsents = c
                m.publisherLegitimateInterests = l
            }
        }
        return m
    }
}
