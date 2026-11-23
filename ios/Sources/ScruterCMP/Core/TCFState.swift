import Foundation

/// The IAB TCF of the app (docs/CMP-MOBILE.md §6), on the engine's queue: the settings of the configuration, the vendor
/// subset and IAB's translations (fetched from the configuration's endpoint and cached), the stored TC string, Google's
/// Additional Consent string and the in-app keys kept in step with every change, the re-ask of rule 5 (docs/CMP.md
/// §4.4), the proof's `tc` and `gv`.
final class CMPTCF {
    static let storedKey = "tcf"
    /// Google's Additional Consent string of the stored decision (a site with Google's other ad tech providers).
    static let acKey = "tcfAc"
    /// Set in the module's suite while keys of ours are in `UserDefaults.standard`.
    static let markerKey = "tcfKeys"

    let env: CMPEnvironment
    /// The vendor list arrived: the engine evaluates again (a vendor the stored string did not disclose).
    var listLoaded: () -> Void = {}
    private(set) var settings: TcfSettings?
    private(set) var list: VendorList?
    private var listName: String?
    private var loading = false
    private var endpoint = ""
    private var waiting: [() -> Void] = []

    @_optimize(size) init(env: CMPEnvironment) { self.env = env }

    var stored: String? { env.kept.read(CMPTCF.storedKey) as? String }
    var storedAc: String? { env.kept.read(CMPTCF.acKey) as? String }
    var on: Bool { settings != nil }

    // MARK: Configuration

    /// A configuration (cached or new): its TCF settings; with the TCF off, nothing of ours stays for vendors to read.
    @_optimize(size) func configure(_ c: CMPConfig?) {
        guard let c = c, let t = c.tcf.flatMap(TcfSettings.init(json:)) else {
            settings = nil
            list = nil
            if env.kept.read(CMPTCF.markerKey) != nil || stored != nil { removeAll() }
            return
        }
        settings = t
        endpoint = c.endpoint
        // Vendors know a CMP is there and the GDPR applies before any choice (IAB in-app: « as soon as it is initialized »).
        var header: [String: Any?] = [
            "IABTCF_CmpSdkID": t.cmpId, "IABTCF_CmpSdkVersion": t.cmpVersion, "IABTCF_PolicyVersion": t.policyVersion,
            "IABTCF_gdprApplies": 1, "IABTCF_PublisherCC": t.cc, "IABTCF_PurposeOneTreatment": 0,
            "IABTCF_UseNonStandardTexts": 0,
        ]
        header = header.filter { k, v in !same(env.iab.read(k), v) }
        if !header.isEmpty { env.iab.write(header) }
        env.kept.write([CMPTCF.markerKey: 1])
        // The stored decision's keys, kept in step (an app or a library may have removed them).
        if let tc = stored,
            (env.iab.read("IABTCF_TCString") as? String) != tc || (env.iab.read("IABTCF_AddtlConsent") as? String) != storedAc
        {
            writeKeys(tc, ac: storedAc)
        }
        let name = "tcf-v-" + CMPTCF.digest(t.vendorsURL) + ".json"
        if name != listName {
            listName = name
            list = env.files.read(name).flatMap(VendorList.init(data:))
            if list == nil { fetchList(name, t) }
        }
    }

    @_optimize(size) private func same(_ a: Any?, _ b: Any?) -> Bool {
        if let x = a as? Int, let y = b as? Int { return x == y }
        if let x = a as? String, let y = b as? String { return x == y }
        return false
    }

    /// Only the configuration's own origin (the web never calls consensu.org: neither does the app).
    @_optimize(size) private func url(_ path: String) -> URL? {
        guard path.hasPrefix("/cmp/"), path.hasSuffix(".json") || path.contains(".json?r=") else { return nil }
        return URL(string: endpoint + path)
    }

    @_optimize(size) private func fetchList(_ name: String, _ t: TcfSettings) {
        guard !loading, let u = url(t.vendorsURL) else { return }
        loading = true
        env.http.send(CMPRequest(method: "GET", url: u, headers: [:], body: nil)) { [weak self] r in
            guard let self = self else { return }
            self.loading = false
            if let r = r, r.status == 200, let l = VendorList(data: r.body), name == self.listName {
                self.env.files.write(name, r.body)
                for old in (try? FileManager.default.contentsOfDirectory(atPath: self.env.files.directory.path)) ?? []
                where old.hasPrefix("tcf-v-") && old != name {
                    self.env.files.remove(old)
                }
                self.list = l
                self.listLoaded()
            }
            let w = self.waiting
            self.waiting = []
            for f in w { f() }
        }
    }

    /// A short, stable file name for a URL (FNV-1a).
    @_optimize(size) static func digest(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 16)
    }

    // MARK: Decisions

    /// docs/CMP.md §4.4 rule 5 for the current settings.
    @_optimize(size) func mustAsk() -> Bool {
        guard let t = settings else { return false }
        return TCF.mustAsk(t, stored: stored, list: list, storedAc: storedAc)
    }

    /// Encodes a decision and writes the string and the keys (before the sheet closes).
    @_optimize(size) func decide(granted: Set<String>, choice: TcfChoice?, config c: CMPConfig, lang: String) {
        guard let t = settings else { return }
        let m = TCF.build(t, list: list, bannerPurposes: c.purposes, lang: lang, now: env.now(), granted: granted, choice: choice)
        let tc = TCString.encode(m)
        let ac = TCF.ac(t, list: list, m, choice: choice).map(TCF.acString)
        env.kept.write([CMPTCF.storedKey: tc, CMPTCF.acKey: ac])
        writeKeys(tc, ac: ac, model: m)
        env.log.log(ac == nil ? "TC string written" : "TC string and Additional Consent string written")
    }

    @_optimize(size) private func writeKeys(_ tc: String, ac: String?, model: TcModel? = nil) {
        guard let m = model ?? TCString.decode(tc) else { return }
        var values: [String: Any?] = Dictionary(uniqueKeysWithValues: TCF.decisionKeys.map { ($0, nil as Any?) })
        for (k, v) in TCF.keys(m, tc: tc, ac: ac) { values[k] = v }
        env.iab.write(values)
        env.kept.write([CMPTCF.markerKey: 1])
    }

    /// The proof's `tc` (the TC string, then Google's Additional Consent string after `~`) and `gv` (docs/CMP.md §6.1).
    @_optimize(size) func proofFields() -> (tc: String, gv: Int)? {
        guard let t = settings, let tc = stored else { return nil }
        return (tc + (storedAc.map { "~" + $0 } ?? ""), t.gvlVersion)
    }

    /// The choice ran out or is gone: no decision is signalled until the next one.
    @_optimize(size) func clearDecision() {
        guard stored != nil else { return }
        env.kept.write([CMPTCF.storedKey: nil, CMPTCF.acKey: nil])
        env.iab.write(Dictionary(uniqueKeysWithValues: TCF.decisionKeys.map { ($0, nil as Any?) }))
    }

    /// `debugReset()`, or the TCF turned off: every key of ours goes.
    @_optimize(size) func removeAll() {
        env.kept.write([CMPTCF.storedKey: nil, CMPTCF.acKey: nil, CMPTCF.markerKey: nil])
        env.iab.write(Dictionary(uniqueKeysWithValues: TCF.allKeys.map { ($0, nil as Any?) }))
    }

    @_optimize(size) func reset() {
        removeAll()
        if settings != nil { listName = nil }
    }

    // MARK: The layers

    /// The vendor list and IAB's texts in `lang` for the sheet, within `budget` seconds (nil: no vendor list, the
    /// standard layers show and nothing is disclosed).
    @_optimize(size) func sheet(lang: String, budget: Double, done: @escaping (VendorList?) -> Void) {
        guard let t = settings else { return done(nil) }
        var finished = false
        let finish: (VendorList?) -> Void = { l in
            guard !finished else { return }
            finished = true
            done(l)
        }
        let timer = env.scheduler.schedule(after: budget) { finish(nil) }
        let withList: () -> Void = { [weak self] in
            guard let self = self, let base = self.list else {
                timer.cancel()
                return finish(nil)
            }
            self.translations(t, lang: lang) { tr in
                timer.cancel()
                // A copy: the texts of one language over the vendor list.
                let l = VendorList(copy: base)
                l.translated(tr, lang: lang)
                finish(l)
            }
        }
        if list != nil { return withList() }
        waiting.append(withList)
        if let n = listName { fetchList(n, t) }
    }

    @_optimize(size) private func translations(_ t: TcfSettings, lang: String, done: @escaping (JSONObject?) -> Void) {
        let l = lang.lowercased()
        if l.hasPrefix("en") { return done(nil) }
        let name = "tcf-t-\(t.gvlVersion)-\(l).json"
        if let j = env.files.readObject(name) { return done(j) }
        guard let u = url(t.translationsURL.replacingOccurrences(of: "{lang}", with: l)) else { return done(nil) }
        env.http.send(CMPRequest(method: "GET", url: u, headers: [:], body: nil)) { [weak self] r in
            guard let r = r, r.status == 200, let j = JSON.object(r.body) else { return done(nil) }
            self?.env.files.write(name, r.body)
            done(j)
        }
    }

    /// The visitor's previous TCF choice, when the stored string is current.
    @_optimize(size) func storedChoice() -> TcfChoice? {
        guard let t = settings, let tc = stored, let m = TCString.decode(tc), !TCF.mustAsk(t, stored: tc, list: nil) else { return nil }
        return TCF.choice(t, m, ac: storedAc.flatMap(TCF.parseAc))
    }
}

/// What the TCF layers draw (docs/CMP.md §4.7 « As built », board M7), prepared on the engine's queue from the settings,
/// the vendor list in the banner's language and the sheet's words.
final class TcfSheet {
    struct Vendor {
        var v: GvlVendor
        /// The IAB purposes it rests on consent and on legitimate interest for, under the publisher's settings.
        var consent: [Int]
        var li: [Int]
        var policyURL: String?
        var liClaimURL: String?
    }

    /// One run of the first layer's sentence; `bold` for what it names.
    struct Run {
        var text: String
        var bold: Bool
    }

    let settings: TcfSettings
    let list: VendorList
    let vendors: [Vendor]
    /// Google's other ad tech providers of the selection, by name (Additional Consent).
    let ac: [AcProvider]
    /// The first layer's IAB text in the message's place, then its small print.
    let first: [Run]
    /// Without stacks (purpose 1 alone): the purposes and special features as a list under `first`.
    let items: [String]
    let note: String
    let hasLi: Bool
    /// The banner purposes the steps show, in order.
    let keys: [String]
    let consentPurposes: [Int]
    let liPurposes: [Int]
    let specialPurposes: [Int]
    let features: [Int]
    let specialFeatures: [Int]
    /// The visitor's previous TCF choice (preferences, a returning visitor), else nil.
    let stored: TcfChoice?
    let renewMonths: Int

    @_optimize(size) init?(
        settings t: TcfSettings, list: VendorList, purposes: [PurposeRef], names: [String: String], words: Words, lang: String,
        stored: TcfChoice?, renewMonths: Int
    ) {
        settings = t
        self.list = list
        self.stored = stored
        self.renewMonths = renewMonths
        let vs = t.vendors.compactMap { list.live($0) }.map {
            Vendor(
                v: $0, consent: TCF.vendorPurposes(t, $0, "consent"), li: TCF.vendorPurposes(t, $0, "legitimate_interest"),
                policyURL: $0.url("privacy", lang: lang), liClaimURL: $0.url("legIntClaim", lang: lang))
        }
        let acs = list.liveAc(t)
        guard !vs.isEmpty || !acs.isEmpty else { return nil }
        vendors = vs.sorted { $0.v.name.localizedCaseInsensitiveCompare($1.v.name) == .orderedAscending }
        ac = acs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        keys = purposes.filter { !$0.required }.map { $0.key }
        let used: (KeyPath<Vendor, [Int]>, [Int]) -> [Int] = { kp, of in of.filter { id in vs.contains { $0[keyPath: kp].contains(id) } } }
        let all = Array(1...TCF.purposes)
        // Google's providers rest on consent for purposes 1, 3 and 4.
        let cps = all.filter { used(\.consent, [$0]).count > 0 || (!acs.isEmpty && TCF.acPurposes.contains($0)) }
        let lps = used(\.li, all)
        consentPurposes = cps
        liPurposes = lps
        specialPurposes = all.filter { p in vs.contains { $0.v.specialPurposes.contains(p) } }
        features = all.filter { p in vs.contains { $0.v.features.contains(p) } }
        let sfs = t.specialFeatures.filter { f in vs.contains { $0.v.specialFeatures.contains(f) } }
        specialFeatures = sfs
        let li = vs.contains { !$0.li.isEmpty }
        hasLi = li
        // Every partner: the IAB's and Google's others.
        let n = vs.count + acs.count
        let shown = all.filter { cps.contains($0) || lps.contains($0) }
        let name: ([Int: TcfText], Int) -> String = { d, id in d[id]?.name ?? "#\(id)" }
        @_optimize(size) func fill(_ s: String) -> String { s.replacingOccurrences(of: "{n}", with: String(n)) }
        @_optimize(size) func bold(_ s: String, _ k: String, _ b: String) -> [Run] {
            guard let r = s.range(of: k) else { return [Run(text: s, bold: false)] }
            return [Run(text: String(s[..<r.lowerBound]), bold: false), Run(text: b, bold: true), Run(text: String(s[r.upperBound...]), bold: false)]
        }
        if shown.contains(1) && shown.count > 1 {
            // Purpose 1 is the sentence itself; first the banner's purposes no IAB purpose is grouped under, then the
            // IAB purposes by the stacks that gather them (`cmp/src/tcf/stacks.ts`).
            let grouped = Set(t.stacks.values)
            let own = purposes.filter { !$0.required && !grouped.contains($0.key) }.map { names[$0.key] ?? $0.key }
            let said = own + TcfSheet.cover(list.stacks, Array(shown.dropFirst())).map { $0 > 0 ? name(list.stacks, $0) : name(list.purposes, -$0) }
            var runs = bold(fill(words.tcfShort), "{s}", TcfSheet.phrase(said, lang))
            if !sfs.isEmpty {
                let fs = TcfSheet.featureStack(list.stacks, sfs)
                let sfNames = fs > 0 ? [name(list.stacks, fs)] : sfs.map { name(list.specialFeatures, $0) }
                runs.append(Run(text: " ", bold: false))
                runs += bold(words.tcfSfShort, "{f}", TcfSheet.phrase(sfNames, lang))
            }
            first = runs.filter { !$0.text.isEmpty }
            items = []
        } else {
            first = [Run(text: fill(words.tcfIntro), bold: false)]
            items = shown.map { name(list.purposes, $0) } + sfs.map { name(list.specialFeatures, $0) }
        }
        note = (li ? words.tcfLiShort + " " : "") + words.tcfScope
    }

    /// The step (banner purpose key) that shows IAB purpose `p`: the one it is grouped under, else (and for the special
    /// features, `p` 0) the one grouping the most IAB purposes.
    @_optimize(size) func place(_ p: Int) -> String? {
        if let k = settings.stacks[p], keys.contains(k) { return k }
        var main = keys.first
        var most = -1
        for k in keys {
            let n = settings.stacks.values.filter { $0 == k }.count
            if n > most {
                main = k
                most = n
            }
        }
        return main
    }

    /// The step the « Intérêt légitime » link opens: the one of the first purpose a vendor rests on it for.
    var liPlace: String? { liPurposes.first.flatMap(place) }

    @_optimize(size) func vendors(of key: KeyPath<Vendor, [Int]>, _ id: Int) -> [Vendor] { vendors.filter { $0[keyPath: key].contains(id) } }

    /// The names of the partners resting on consent for IAB purpose `p`: the IAB's, then Google's for 1, 3 and 4.
    @_optimize(size) func consentNames(_ p: Int) -> [String] {
        vendors(of: \.consent, p).map { $0.v.name } + (TCF.acPurposes.contains(p) ? ac.map { $0.name } : [])
    }

    /// `items` as one phrase of the language (« a, b et c »); names inside a sentence start in lower case, but in German.
    @_optimize(size) static func phrase(_ items: [String], _ lang: String) -> String {
        let low = items.map { s -> String in
            lang.lowercased().hasPrefix("de") || s.isEmpty ? s : s.prefix(1).lowercased() + s.dropFirst()
        }
        #if canImport(Darwin)
        let f = ListFormatter()
        f.locale = Locale(identifier: lang)
        if let s = f.string(from: low) { return s }
        #endif
        return low.joined(separator: ", ")
    }

    /// The stacks of purposes only that say `want` (IAB purposes 2–11), disjoint, the fewest first; where no exact cover
    /// exists, those covering the most, then the remaining purposes alone: stack ids (> 0) and purposes (< 0).
    @_optimize(size) static func cover(_ stacks: [Int: TcfText], _ want: [Int]) -> [Int] {
        let mask: ([Int]) -> Int = { $0.reduce(0) { $0 | (1 << $1) } }
        let all = mask(want)
        let cand = stacks.compactMap { id, s -> (Int, Int)? in
            let m = mask(s.purposes)
            return m != 0 && s.specialFeatures.isEmpty && m & ~all == 0 ? (id, m) : nil
        }.sorted { $0.0 < $1.0 }
        var best: [Int: [Int]] = [0: []]
        var queue = [0]
        var top = 0
        var i = 0
        while i < queue.count {
            let m = queue[i]
            i += 1
            if m.nonzeroBitCount > top.nonzeroBitCount { top = m }
            for (id, c) in cand where m & c == 0 && best[m | c] == nil {
                best[m | c] = best[m]! + [id]
                queue.append(m | c)
            }
        }
        return best[top]!.sorted() + want.filter { top & (1 << $0) == 0 }.map { -$0 }
    }

    /// The stack of special features only that gathers exactly `sf` (stack 1: both), else 0.
    @_optimize(size) static func featureStack(_ stacks: [Int: TcfText], _ sf: [Int]) -> Int {
        let mask: ([Int]) -> Int = { $0.reduce(0) { $0 | (1 << $1) } }
        return stacks.filter { $0.value.purposes.isEmpty && mask($0.value.specialFeatures) == mask(sf) }.keys.min() ?? 0
    }
}
