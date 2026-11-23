import Foundation

/// What a proof records as the visitor's action (docs/CMP.md §6.1).
enum CMPAction: String, CaseIterable {
    case acceptAll = "accept_all"
    case rejectAll = "reject_all"
    case custom
    case close
    case withdraw

    /// One letter in the stored value's pending flag (`a r c x w`).
    var letter: Character { Array("arcxw")[CMPAction.allCases.firstIndex(of: self)!] }
}

/// Where the decision was made (`floating_button` exists on the web only: parsed, never sent by an app).
enum CMPSource: String, CaseIterable {
    case banner
    case preferences
    case floatingButton = "floating_button"
    case api

    var letter: Character { Array("bpfi")[CMPSource.allCases.firstIndex(of: self)!] }
}

/// The stored choice, format 1 (docs/CMP.md §4.3, docs/CMP-MOBILE.md M5): the value of the web's `scruter_consent`
/// cookie, kept under the key `choice` of `UserDefaults(suiteName: "net.scruter.cmp")`.
///
/// `1.<consent id>.<decided at, base 36 seconds>.<consent_rev>.<banner version id>.<granted keys joined by +>.<flags>`;
/// flags are empty, or `p<action><source>` while the proof is not acknowledged.
struct StoredChoice: Equatable {
    struct Pending: Equatable {
        var action: CMPAction
        var source: CMPSource
    }

    /// `cns_` + 20 lowercase hex digits.
    var id: String
    /// Unix seconds.
    var at: Int64
    var rev: Int
    var banner: Int
    var granted: [String]
    var pending: Pending?

    @_optimize(size) static func parse(_ value: String) -> StoredChoice? {
        let f = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 7, f[0] == "1", isConsentId(f[1]), f[2].count >= 1, f[2].count <= 8,
            f[2].allSatisfy({ ("0"..."9").contains($0) || ("a"..."z").contains($0) }),
            let at = Int64(f[2], radix: 36), let rev = smallInt(f[3]), let banner = smallInt(f[4])
        else { return nil }
        let granted = f[5].isEmpty ? [] : f[5].split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard granted.allSatisfy(isPurposeKey) else { return nil }
        var pending: Pending?
        if !f[6].isEmpty {
            let p = Array(f[6])
            guard p.count == 3, p[0] == "p",
                let a = CMPAction.allCases.first(where: { $0.letter == p[1] }),
                let o = CMPSource.allCases.first(where: { $0.letter == p[2] })
            else { return nil }
            pending = Pending(action: a, source: o)
        }
        return StoredChoice(id: f[1], at: at, rev: rev, banner: banner, granted: granted, pending: pending)
    }

    var serialized: String {
        let flags = pending.map { "p" + String($0.action.letter) + String($0.source.letter) } ?? ""
        return ["1", id, String(at, radix: 36), String(rev), String(banner), granted.joined(separator: "+"), flags]
            .joined(separator: ".")
    }

    @_optimize(size) static func isConsentId(_ s: String) -> Bool {
        s.count == 24 && s.hasPrefix("cns_") && s.dropFirst(4).allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// `^[a-z][a-z0-9_]{1,39}$`
    @_optimize(size) static func isPurposeKey(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 40, let first = s.first, ("a"..."z").contains(first) else { return false }
        return s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// `^[0-9]{1,10}$`, as the web reads it.
    @_optimize(size) private static func smallInt(_ s: String) -> Int? {
        guard s.count >= 1, s.count <= 10, s.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(s)
    }

    /// `cns_` + 80 random bits.
    @_optimize(size) static func newConsentId() -> String {
        var g = SystemRandomNumberGenerator()
        var s = "cns_"
        for _ in 0..<10 {
            let b = UInt8.random(in: 0...255, using: &g)
            s += String(b >> 4, radix: 16) + String(b & 15, radix: 16)
        }
        return s
    }
}

enum Rules {
    /// The re-consent period in seconds: months × 30.44 days, rounded (the web cookie's Max-Age).
    @_optimize(size) static func renewSeconds(_ months: Int) -> Int64 {
        Int64((Double(months) * 30.44 * 86400).rounded())
    }

    /// Why the first layer must show again (docs/CMP.md §4.4 rules 1–4); `nil` when the stored choice holds.
    enum Reask: Equatable {
        case noChoice
        case expired
        /// A purpose that may be new, or a granted purpose whose meaning changed: the keys concerned.
        case changed(Set<String>)
    }

    /// Rules 1–4 (`sdk/protocol/cmp/vectors/reask.json`): the period ran out; a purpose the visitor granted changed
    /// since (`rev` newer than the choice's); a purpose that may be new (newer `rev`, not granted, and the choice
    /// names an older banner version than the current one or the running variant).
    static func reask(_ s: StoredChoice?, renewMonths: Int, banner: Int, abTestB: Int?, purposes: [PurposeRef], now: Int64)
        -> Reask?
    {
        guard let s = s else { return .noChoice }
        if now - s.at > renewSeconds(renewMonths) { return .expired }
        let current = s.banner == banner || (abTestB != nil && s.banner == abTestB)
        var changed = Set<String>()
        for p in purposes where !p.required && p.rev > s.rev {
            if s.granted.contains(p.key) || !current { changed.insert(p.key) }
        }
        return changed.isEmpty ? nil : .changed(changed)
    }

    @_optimize(size) static func reask(_ s: StoredChoice?, config c: CMPConfig, now: Int64) -> Reask? {
        reask(s, renewMonths: c.renew_months, banner: c.banner.id, abTestB: c.ab_test?.b.id, purposes: c.purposes, now: now)
    }

    /// The first of `preferred` (an explicit language, then the device's) the banner speaks: the exact tag, its alias
    /// (`no` → `nb`), the primary subtag (`pt-BR` → `pt`, `zh-Hant-TW` → `zh`), its alias; else `fallback`
    /// (`cmp/src/core/lang.ts`).
    @_optimize(size) static func pickLanguage(enabled: [String], fallback: String, preferred: [String], aliases: [String: String]) -> String {
        for raw in preferred {
            let l = raw.lowercased().replacingOccurrences(of: "_", with: "-")
            let p = String(l.split(separator: "-").first ?? Substring(l))
            for c in [l, aliases[l], p, aliases[p]] {
                if let c = c, enabled.contains(c) { return c }
            }
        }
        return fallback
    }

    /// The action a proof records for a set of choices (as the web's `decide`): an explicit button keeps its action;
    /// « Enregistrer » is `reject_all` when nothing is granted, `accept_all` when everything is, else `custom`; every
    /// optional purpose refused after at least one had been granted is a `withdraw`.
    @_optimize(size) static func action(explicit: CMPAction?, granted: [String], denied: [String], before: Set<String>?) -> CMPAction {
        var a = explicit ?? (granted.isEmpty ? .rejectAll : denied.isEmpty ? .acceptAll : .custom)
        if granted.isEmpty, let b = before, !b.isEmpty { a = .withdraw }
        return a
    }
}

/// Google Consent Mode v2 (docs/CMP.md §4.8, `sdk/protocol/cmp/vectors/consent-mode.json`).
enum ConsentModeRules {
    static let order = [
        "ad_storage", "ad_user_data", "ad_personalization", "analytics_storage", "functionality_storage",
        "personalization_storage", "security_storage",
    ]

    /// The web's default mapping: used when the banner has no Consent Mode settings, so `consentModeSignals()` is
    /// always meaningful.
    static let defaultMap = [
        "ad_storage": "advertising", "ad_user_data": "advertising", "ad_personalization": "advertising",
        "analytics_storage": "analytics", "personalization_storage": "personalization",
    ]

    /// Every signal: granted when its mapped purpose is granted, `security_storage` always granted.
    @_optimize(size) static func signals(map: [String: String], granted: Set<String>?) -> [String: Bool] {
        var out = [String: Bool]()
        for s in order {
            out[s] = s == "security_storage" || (granted.map { g in map[s].map { g.contains($0) } ?? false } ?? false)
        }
        return out
    }

    /// The signals sent as granted, in order: the proof's `m`.
    @_optimize(size) static func grantedSignals(map: [String: String], granted: Set<String>) -> [String] {
        let s = signals(map: map, granted: granted)
        return order.filter { s[$0] == true }
    }
}

/// French typography on display (docs/CMP.md §4.5, `cmp/src/ui/labels.ts` `frenchSpacing`): a narrow no-break space
/// after « and before », ; : ! ?. The stored texts, their hashes and the proofs are untouched.
enum Typography {
    private static let narrow: Character = "\u{202F}"

    @_optimize(size) static func frenchSpacing(_ s: String) -> String {
        let chars = Array(s)
        var out = [Character]()
        out.reserveCapacity(chars.count + 8)
        @_optimize(size) func isSpace(_ c: Character) -> Bool { c == " " || c == "\u{00A0}" || c == narrow }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "«" {
                out.append(c)
                out.append(narrow)
                if i + 1 < chars.count, isSpace(chars[i + 1]) { i += 1 }
                i += 1
                continue
            }
            if c == "»" {
                if let last = out.last, isSpace(last) { out.removeLast() }
                out.append(narrow)
                out.append(c)
                i += 1
                continue
            }
            if ";:!?".contains(c) {
                // A run of punctuation followed by whitespace, a closing guillemet or the end.
                var j = i
                while j < chars.count, ";:!?".contains(chars[j]) { j += 1 }
                let after: Character? = j < chars.count ? chars[j] : nil
                let ends = after == nil || after!.isWhitespace || after == "»" || after == narrow
                if ends {
                    if let last = out.last, last == " " || last == "\u{00A0}" {
                        out.removeLast()
                        out.append(narrow)
                    } else if let last = out.last, !last.isWhitespace, last != narrow, last != "«" {
                        out.append(narrow)
                    }
                }
                out.append(contentsOf: chars[i..<j])
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }
}
