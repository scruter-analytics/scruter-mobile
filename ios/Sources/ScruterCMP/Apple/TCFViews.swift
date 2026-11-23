#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// The pages of the TCF layers that are not a step (boards M7 and M15): every IAB purpose (the preferences), the
/// partners (the preferences), one partner's declarations, one of Google's other ad tech providers.
enum CMPTcfPage: Equatable {
    case purposes
    case partners
    case vendor(Int)
    case ac(Int)
}

/// The TCF switches of a display (the site script's `TcfEdit` and `settle`): untouched IAB purposes follow the banner
/// purpose they are grouped under (all of them when none), untouched partners follow the IAB purposes their consent rests
/// on; a returning visitor's stored choice holds until a banner or IAB purpose is moved.
extension CMPSheetState {
    @_optimize(size) func bannerGrants(_ p: Int) -> Bool {
        guard let t = model.tcf else { return false }
        if let k = t.settings.stacks[p] { return granted.contains(k) }
        return model.purposes.allSatisfy { granted.contains($0.key) }
    }

    private var follows: Bool { model.tcf?.stored == nil || tcfMoved }

    @_optimize(size) func iabPurpose(_ p: Int) -> Bool {
        if touched.contains("p\(p)") { return tcfChoice.purposes?[p] ?? false }
        return follows ? bannerGrants(p) : (model.tcf?.stored?.purposes?[p] ?? bannerGrants(p))
    }

    @_optimize(size) func vendorConsent(_ v: TcfSheet.Vendor) -> Bool {
        if touched.contains("v\(v.v.id)") { return tcfChoice.vendors[v.v.id] ?? false }
        let derived = !v.consent.isEmpty && v.consent.allSatisfy(iabPurpose)
        return follows ? derived : (model.tcf?.stored?.vendors[v.v.id] ?? derived)
    }

    @_optimize(size) func vendorLi(_ id: Int) -> Bool { tcfChoice.vendorsLi[id] ?? model.tcf?.stored?.vendorsLi[id] ?? true }
    @_optimize(size) func purposeLi(_ p: Int) -> Bool { tcfChoice.purposesLi[p] ?? model.tcf?.stored?.purposesLi[p] ?? true }
    @_optimize(size) func specialFeature(_ f: Int) -> Bool { tcfChoice.specialFeatures[f] ?? model.tcf?.stored?.specialFeatures[f] ?? false }

    @_optimize(size) func setPurpose(_ p: Int, _ on: Bool) {
        touched.insert("p\(p)")
        tcfMoved = true
        var set = tcfChoice.purposes ?? [:]
        set[p] = on
        tcfChoice.purposes = set
    }

    @_optimize(size) func setVendor(_ id: Int, _ on: Bool) {
        touched.insert("v\(id)")
        tcfChoice.vendors[id] = on
    }

    /// One of Google's providers: untouched, it follows purposes 1, 3 and 4 (as an IAB partner follows its purposes).
    @_optimize(size) func acConsent(_ id: Int) -> Bool {
        if touched.contains("a\(id)") { return tcfChoice.ac[id] ?? false }
        let derived = TCF.acPurposes.allSatisfy(iabPurpose)
        return follows ? derived : (model.tcf?.stored?.ac[id] ?? derived)
    }

    @_optimize(size) func setAc(_ id: Int, _ on: Bool) {
        touched.insert("a\(id)")
        tcfChoice.ac[id] = on
    }

    /// The TCF choice « Enregistrer » sends: every switch shown or derived.
    @_optimize(size) func settledTcf() -> TcfChoice? {
        guard let t = model.tcf else { return nil }
        var c = TcfChoice()
        c.purposes = [:]
        for p in t.consentPurposes { c.purposes?[p] = iabPurpose(p) }
        for v in t.vendors {
            if !v.consent.isEmpty { c.vendors[v.v.id] = vendorConsent(v) }
            if !v.li.isEmpty { c.vendorsLi[v.v.id] = vendorLi(v.v.id) }
        }
        for p in t.liPurposes { c.purposesLi[p] = purposeLi(p) }
        for f in t.specialFeatures { c.specialFeatures[f] = specialFeature(f) }
        for a in t.ac { c.ac[a.id] = acConsent(a.id) }
        return c
    }
}

/// The first layer's IAB text in the message's place, its small print and inline links (board M7, 1).
struct CMPTcfFirst: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette

    @_optimize(size) var body: some View {
        let t = state.model.tcf!
        let w = state.model.words
        VStack(alignment: .leading, spacing: 6) {
            t.first.reduce(Text("")) { acc, r in
                acc + (r.bold ? Text(r.text).fontWeight(.semibold).foregroundColor(palette.text.color) : Text(r.text))
            }
            .font(.subheadline)
            .foregroundColor(palette.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("scruter-cmp-tcf-text")
            ForEach(t.items, id: \.self) { item in
                Text("•  " + item).font(.subheadline).foregroundColor(palette.secondary.color).fixedSize(horizontal: false, vertical: true)
            }
            Text(note(t, w))
                .font(.footnote)
                .foregroundColor(palette.secondary.color)
                .tint(palette.text.color)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "scruter-cmp" {
                        state.openTcf(url.host ?? "")
                    } else {
                        state.open(url)
                    }
                    return .handled
                })
                .accessibilityIdentifier("scruter-cmp-tcf-note")
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// The small print: legitimate interest and the scope, then « Voir nos n partenaires » · « Intérêt légitime » · the
    /// app's privacy policy, as links in the text.
    @_optimize(size) private func note(_ t: TcfSheet, _ w: Words) -> AttributedString {
        var s = AttributedString(t.note + " ")
        @_optimize(size) func link(_ text: String, _ url: String) {
            var a = AttributedString(text)
            a.link = URL(string: url)
            a.foregroundColor = palette.text.color
            a.underlineStyle = .single
            a.inlinePresentationIntent = .stronglyEmphasized
            s += a
        }
        // Every partner: the IAB's and Google's others.
        link(w.viewPartners.replacingOccurrences(of: "{n}", with: String(t.vendors.count + t.ac.count)), "scruter-cmp://partners")
        if t.hasLi {
            s += AttributedString(" · ")
            link(w.li, "scruter-cmp://li")
        }
        if let p = state.model.policyURL, p.hasPrefix("http") {
            s += AttributedString(" · ")
            link(w.privacy, p)
        }
        return s
    }
}

/// A row of the TCF layers: its title, what it says, and its switch (none for what the visitor cannot refuse).
struct CMPTcfRow<Extra: View>: View {
    let title: String
    let palette: Palette
    let isOn: Binding<Bool>?
    let id: String
    @ViewBuilder var extra: () -> Extra

    @_optimize(size) var body: some View {
        VStack(spacing: 0) {
            palette.line.color.frame(height: 1)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundColor(palette.text.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(isOn != nil)
                    extra()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let b = isOn {
                    Toggle(isOn: b) { Text(title) }
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: palette.brand.color))
                        .accessibilityLabel(title)
                        .accessibilityIdentifier(id)
                }
            }
            .padding(.vertical, 8)
            .frame(minHeight: 44)
        }
    }
}

/// A section title of the TCF layers.
struct CMPTcfHeading: View {
    let text: String
    let palette: Palette

    @_optimize(size) var body: some View {
        Text(text).font(.caption.weight(.bold)).textCase(.uppercase).foregroundColor(palette.secondary.color)
            .padding(.top, 16).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// An IAB purpose's standard text, examples and the partners concerned (their names), the last two folded.
struct CMPTcfAbout: View {
    let text: TcfText?
    let vendors: [String]
    let words: Words
    let palette: Palette

    @_optimize(size) var body: some View {
        if let d = text?.description, !d.isEmpty {
            Text(d).font(.footnote).foregroundColor(palette.secondary.color).fixedSize(horizontal: false, vertical: true)
        }
        if let ill = text?.illustrations, !ill.isEmpty {
            fold(words.examples, ill.joined(separator: "\n\n"))
        }
        if !vendors.isEmpty {
            fold(words.partners.replacingOccurrences(of: "{n}", with: String(vendors.count)), vendors.joined(separator: ", "))
        }
    }

    @_optimize(size) private func fold(_ title: String, _ body: String) -> some View {
        DisclosureGroup {
            Text(body).font(.footnote).foregroundColor(palette.secondary.color).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.footnote.weight(.semibold)).foregroundColor(palette.text.color).frame(minHeight: 44, alignment: .leading)
        }
        .accentColor(palette.text.color)
    }
}

/// The IAB purposes of a step (the banner purpose `key`), or all of them (`key` nil, the preferences): consent switches,
/// the objections to legitimate interest, the special features (board M15, 1).
struct CMPTcfPurposes: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette
    let key: String?

    @_optimize(size) var body: some View {
        let t = state.model.tcf!
        let w = state.model.words
        let mine: (Int) -> Bool = { p in key == nil || t.place(p) == key }
        let cp = t.consentPurposes.filter(mine)
        let lp = t.liPurposes.filter(mine)
        let sf = key == nil || t.place(0) == key ? t.specialFeatures : []
        VStack(alignment: .leading, spacing: 0) {
            if !cp.isEmpty {
                CMPTcfHeading(text: w.iabPurposes + " — " + w.consent, palette: palette)
                ForEach(cp, id: \.self) { p in
                    CMPTcfRow(
                        title: tcfName(t.list.purposes, p), palette: palette,
                        isOn: Binding(get: { state.iabPurpose(p) }, set: { state.setPurpose(p, $0) }), id: "scruter-cmp-iab-\(p)"
                    ) {
                        CMPTcfAbout(text: t.list.purposes[p], vendors: t.consentNames(p), words: w, palette: palette)
                    }
                }
            }
            if !lp.isEmpty {
                CMPTcfHeading(text: w.li, palette: palette).id("li")
                Text(w.liIntro).font(.footnote).foregroundColor(palette.secondary.color).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                ForEach(lp, id: \.self) { p in
                    CMPTcfRow(
                        title: tcfName(t.list.purposes, p), palette: palette,
                        isOn: Binding(get: { state.purposeLi(p) }, set: { state.tcfChoice.purposesLi[p] = $0 }), id: "scruter-cmp-li-\(p)"
                    ) {
                        CMPTcfAbout(text: t.list.purposes[p], vendors: t.vendors(of: \.li, p).map { $0.v.name }, words: w, palette: palette)
                    }
                }
            }
            if !sf.isEmpty {
                CMPTcfHeading(text: w.specialFeatures, palette: palette)
                ForEach(sf, id: \.self) { f in
                    CMPTcfRow(
                        title: tcfName(t.list.specialFeatures, f), palette: palette,
                        isOn: Binding(get: { state.specialFeature(f) }, set: { state.tcfChoice.specialFeatures[f] = $0 }), id: "scruter-cmp-sf-\(f)"
                    ) {
                        CMPTcfAbout(
                            text: t.list.specialFeatures[f], vendors: t.vendors.filter { $0.v.specialFeatures.contains(f) }.map { $0.v.name },
                            words: w, palette: palette)
                    }
                }
            }
        }
    }
}

/// An IAB text's name, else its id.
@_optimize(size) func tcfName(_ d: [Int: TcfText], _ id: Int) -> String { d[id]?.name ?? "#\(id)" }

/// The partners (board M7, 2; M15, 2): IAB's notice, a search, each partner with its consent and its declarations one
/// tap away, Google's other ad tech providers in their own group, then what nobody can refuse (special purposes,
/// features) and how the app keeps the choice.
struct CMPTcfPartners: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette
    @State private var query = ""

    @_optimize(size) var body: some View {
        let t = state.model.tcf!
        let w = state.model.words
        let shown = query.isEmpty ? t.vendors : t.vendors.filter { $0.v.name.localizedCaseInsensitiveContains(query) }
        let acShown = query.isEmpty ? t.ac : t.ac.filter { $0.name.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 0) {
            Text(w.tcfTitle.replacingOccurrences(of: "{n}", with: String(t.vendors.count)))
                .font(.title3.weight(.bold)).foregroundColor(palette.text.color).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("scruter-cmp-partners")
            Text(w.tcfPrefsIntro).font(.footnote).foregroundColor(palette.secondary.color).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            Text(w.tcfLimits.replacingOccurrences(of: "{b}", with: tcfName(t.list.specialPurposes, 1)))
                .font(.footnote).foregroundColor(palette.secondary.color).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(palette.secondary.color).accessibilityHidden(true)
                TextField(w.tcfSearch, text: $query)
                    .font(.body)
                    .foregroundColor(palette.text.color)
                    .disableAutocorrection(true)
                    .accessibilityLabel(w.tcfSearch)
                    .accessibilityIdentifier("scruter-cmp-search")
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.soft.color))
            .padding(.vertical, 10)
            ForEach(shown, id: \.v.id) { v in vendorRow(v, w) }
            if !acShown.isEmpty {
                // Google's other ad tech providers (Additional Consent): apart from the TCF's partners (board M7, 2).
                CMPTcfHeading(text: w.acTitle.replacingOccurrences(of: "{n}", with: String(t.ac.count)), palette: palette)
                    .accessibilityIdentifier("scruter-cmp-ac")
                Text(w.acIntro).font(.footnote).foregroundColor(palette.secondary.color).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                ForEach(acShown, id: \.id) { a in acRow(a, w) }
            }
            if !t.specialPurposes.isEmpty {
                CMPTcfHeading(text: w.specialPurposes, palette: palette)
                ForEach(t.specialPurposes, id: \.self) { p in
                    CMPTcfRow(title: tcfName(t.list.specialPurposes, p), palette: palette, isOn: nil, id: "") {
                        CMPTcfAbout(
                            text: t.list.specialPurposes[p], vendors: t.vendors.filter { $0.v.specialPurposes.contains(p) }.map { $0.v.name },
                            words: w, palette: palette)
                    }
                }
            }
            if !t.features.isEmpty {
                CMPTcfHeading(text: w.features, palette: palette)
                Text(t.list.featuresText ?? w.featuresText).font(.footnote).foregroundColor(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
                ForEach(t.features, id: \.self) { f in
                    CMPTcfRow(title: tcfName(t.list.features, f), palette: palette, isOn: nil, id: "") {
                        CMPTcfAbout(
                            text: t.list.features[f], vendors: t.vendors.filter { $0.v.features.contains(f) }.map { $0.v.name }, words: w,
                            palette: palette)
                    }
                }
            }
            Text(w.tcfStorage.replacingOccurrences(of: "{n}", with: String(t.renewMonths)))
                .font(.footnote).foregroundColor(palette.secondary.color).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
        }
    }

    @_optimize(size) private func vendorRow(_ v: TcfSheet.Vendor, _ w: Words) -> some View {
        let bases = (v.consent.isEmpty ? [] : [w.consent]) + (v.li.isEmpty ? [] : [w.li])
        let id = v.v.id
        return partnerRow(
            v.v.name, bases.joined(separator: " · "), .vendor(id), kind: "vendor", id: id, w,
            consent: v.consent.isEmpty ? nil : Binding(get: { state.vendorConsent(v) }, set: { state.setVendor(id, $0) }))
    }

    @_optimize(size) private func acRow(_ a: AcProvider, _ w: Words) -> some View {
        partnerRow(a.name, w.consent, .ac(a.id), kind: "ac", id: a.id, w, consent: Binding(get: { state.acConsent(a.id) }, set: { state.setAc(a.id, $0) }))
    }

    /// A partner of the list (an IAB vendor or one of Google's providers): its name and bases, its page one tap away,
    /// its consent switch; `scruter-cmp-<kind>-<id>` and `scruter-cmp-<kind>-consent-<id>` for tests.
    @_optimize(size) private func partnerRow(
        _ name: String, _ sub: String, _ page: CMPTcfPage, kind: String, id: Int, _ w: Words, consent: Binding<Bool>?
    ) -> some View {
        VStack(spacing: 0) {
            palette.line.color.frame(height: 1)
            HStack(spacing: 8) {
                Button {
                    state.go(page)
                } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.callout.weight(.semibold)).foregroundColor(palette.text.color)
                            Text(sub).font(.footnote).foregroundColor(palette.secondary.color)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundColor(palette.secondary.color)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CMPPressStyle())
                .accessibilityIdentifier("scruter-cmp-\(kind)-\(id)")
                if let b = consent {
                    Toggle(isOn: b) { Text(name) }
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: palette.brand.color))
                        .accessibilityLabel(name + " — " + w.consent)
                        .accessibilityIdentifier("scruter-cmp-\(kind)-consent-\(id)")
                }
            }
        }
    }
}

/// One of Google's other ad tech providers: its consent, what that consent allows, its privacy policy (Google's list
/// gives no more).
struct CMPTcfAcProvider: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette
    let id: Int

    @_optimize(size) var body: some View {
        let w = state.model.words
        if let a = state.model.tcf?.ac.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 0) {
                Text(a.name).font(.title3.weight(.bold)).foregroundColor(palette.text.color).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 6)
                CMPTcfRow(
                    title: w.consent, palette: palette, isOn: Binding(get: { state.acConsent(id) }, set: { state.setAc(id, $0) }),
                    id: "scruter-cmp-detail-consent"
                ) {
                    Text(w.acProviderIntro).font(.footnote).foregroundColor(palette.secondary.color).fixedSize(horizontal: false, vertical: true)
                }
                if let u = a.policyURL.flatMap(URL.init(string:)) {
                    Button { state.open(u) } label: {
                        Text(w.privacy).font(.subheadline.weight(.semibold)).underline().foregroundColor(palette.text.color)
                            .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(CMPPressStyle())
                    .accessibilityAddTraits(.isLink)
                    .accessibilityRemoveTraits(.isButton)
                }
            }
        }
    }
}

/// One partner (board M7, 3): its consent and objection, its purposes with their retention, its special purposes,
/// features and special features, the data it uses, what it stores on the device, its policies.
struct CMPTcfVendor: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette
    let id: Int

    @_optimize(size) var body: some View {
        let t = state.model.tcf!
        let w = state.model.words
        if let v = t.vendors.first(where: { $0.v.id == id }) {
            VStack(alignment: .leading, spacing: 0) {
                Text(v.v.name).font(.title3.weight(.bold)).foregroundColor(palette.text.color).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 6)
                if !v.consent.isEmpty {
                    CMPTcfRow(
                        title: w.consent, palette: palette, isOn: Binding(get: { state.vendorConsent(v) }, set: { state.setVendor(id, $0) }),
                        id: "scruter-cmp-detail-consent"
                    ) { list(v.consent, t.list.purposes, v.v.retention, w) }
                }
                if !v.li.isEmpty {
                    CMPTcfRow(
                        title: w.li, palette: palette, isOn: Binding(get: { state.vendorLi(id) }, set: { state.tcfChoice.vendorsLi[id] = $0 }),
                        id: "scruter-cmp-detail-li"
                    ) { list(v.li, t.list.purposes, v.v.retention, w) }
                }
                fact(w.specialPurposes, v.v.specialPurposes, t.list.specialPurposes, v.v.retentionSp, w)
                fact(w.features, v.v.features, t.list.features, nil, w)
                fact(w.specialFeatures, v.v.specialFeatures, t.list.specialFeatures, nil, w)
                fact(w.dataCategories, v.v.dataDeclaration, t.list.dataCategories, nil, w)
                ForEach(storage(v.v, w), id: \.self) { s in
                    Text(s).font(.footnote).foregroundColor(palette.secondary.color).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
                link(w.privacy, v.policyURL)
                link(w.liClaim, v.liClaimURL)
                link(w.storageDetails, v.v.deviceStorageDisclosureURL.flatMap { $0.hasPrefix("https://") ? $0 : nil })
            }
        }
    }

    @_optimize(size) private func days(_ n: Int?, _ w: Words) -> String {
        n.map { " (" + w.retention.replacingOccurrences(of: "{n}", with: String($0)) + ")" } ?? ""
    }

    @_optimize(size) private func list(_ ids: [Int], _ texts: [Int: TcfText], _ keep: [Int: Int]?, _ w: Words) -> some View {
        Text(ids.map { "•  " + tcfName(texts, $0) + days(keep?[$0], w) }.joined(separator: "\n"))
            .font(.footnote).foregroundColor(palette.secondary.color).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func fact(_ title: String, _ ids: [Int], _ texts: [Int: TcfText], _ keep: [Int: Int]?, _ w: Words) -> some View {
        if !ids.isEmpty {
            CMPTcfHeading(text: title, palette: palette)
            list(ids, texts, keep, w)
        }
    }

    /// Retention, the cookies' duration and renewal, other means than cookies (D(c)(VI)).
    @_optimize(size) private func storage(_ v: GvlVendor, _ w: Words) -> [String] {
        var out = [String]()
        if let d = v.stdRetention { out.append(w.retention.replacingOccurrences(of: "{n}", with: String(d))) }
        if v.usesCookies, let s = v.cookieMaxAgeSeconds {
            let colon = w.colon
            out.append(w.duration + colon + CMPTcfVendor.duration(s, lang: state.model.lang, w) + (v.cookieRefresh ? ", " + w.refresh : ""))
        }
        if v.usesNonCookieAccess { out.append(w.nonCookie) }
        return out
    }

    /// « 13 mois », « 1 an » in the banner's language (the site script's `duration`).
    @_optimize(size) static func duration(_ seconds: Int, lang: String, _ w: Words) -> String {
        if seconds < 0 { return w.persistent }
        let day = 86_400
        var c = DateComponents()
        if seconds < day {
            c.hour = max(1, Int((Double(seconds) / 3600).rounded()))
        } else if seconds < 60 * day {
            c.day = Int((Double(seconds) / Double(day)).rounded())
        } else if seconds < 730 * day {
            c.month = Int((Double(seconds) / (30.44 * Double(day))).rounded())
        } else {
            c.year = Int((Double(seconds) / (365.25 * Double(day))).rounded())
        }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: lang)
        f.calendar = cal
        return f.string(from: c) ?? ""
    }

    @ViewBuilder private func link(_ title: String, _ url: String?) -> some View {
        if let u = url.flatMap(URL.init(string:)) {
            Button { state.open(u) } label: {
                Text(title).font(.subheadline.weight(.semibold)).underline().foregroundColor(palette.text.color)
                    .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(CMPPressStyle())
            .accessibilityAddTraits(.isLink)
            .accessibilityRemoveTraits(.isButton)
        }
    }
}

/// A page of the TCF layers with its way back (the preferences' rows, a partner from the list).
struct CMPTcfPageView: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette
    let page: CMPTcfPage

    @_optimize(size) var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: state.back) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(palette.text.color)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CMPPressStyle())
            .accessibilityLabel(state.model.words.back)
            .accessibilityIdentifier("scruter-cmp-tcf-back")
            .padding(.leading, -10)
            switch page {
            case .purposes: CMPTcfPurposes(state: state, palette: palette, key: nil)
            case .partners: CMPTcfPartners(state: state, palette: palette)
            case .vendor(let id): CMPTcfVendor(state: state, palette: palette, id: id)
            case .ac(let id): CMPTcfAcProvider(state: state, palette: palette, id: id)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(String(describing: page))
    }
}

/// The preferences' two ways into the TCF layers (board M15, 3).
struct CMPTcfPreferenceRows: View {
    @ObservedObject var state: CMPSheetState
    let palette: Palette

    @_optimize(size) var body: some View {
        let t = state.model.tcf!
        let w = state.model.words
        let kinds = (t.consentPurposes.isEmpty ? [] : [w.consent]) + (t.liPurposes.isEmpty ? [] : [w.li])
            + (t.specialFeatures.isEmpty ? [] : [w.specialFeatures])
        VStack(spacing: 0) {
            row(w.iabPurposes, kinds.joined(separator: " · "), .purposes, "scruter-cmp-tcf-purposes")
            row(
                w.tcfTitle.replacingOccurrences(of: "{n}", with: String(t.vendors.count)),
                t.ac.isEmpty ? "" : w.acTitle.replacingOccurrences(of: "{n}", with: String(t.ac.count)), .partners, "scruter-cmp-tcf-partners")
        }
    }

    @_optimize(size) private func row(_ title: String, _ sub: String, _ page: CMPTcfPage, _ id: String) -> some View {
        VStack(spacing: 0) {
            palette.line.color.frame(height: 1)
            Button { state.go(page) } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.callout.weight(.semibold)).foregroundColor(palette.text.color)
                        if !sub.isEmpty { Text(sub).font(.footnote).foregroundColor(palette.secondary.color) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundColor(palette.secondary.color)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 64)
                .contentShape(Rectangle())
            }
            .buttonStyle(CMPPressStyle())
            .accessibilityIdentifier(id)
        }
    }
}
#endif
