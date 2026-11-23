import Foundation
import ScruterCMP

/// Stand-ins for the third-party SDKs an app gates on the CMP's answer (CMP.md, « Gate your SDKs »): the same calls as
/// Firebase Analytics, Google Mobile Ads and a mobile measurement partner, without linking them.
final class Partners: ObservableObject {
    static let shared = Partners()

    /// Firebase Analytics: collection on, and its Consent Mode signals (`Analytics.setConsent`).
    @Published private(set) var analyticsStarted = false
    @Published private(set) var consentMode: [String: String] = [:]
    /// Google Mobile Ads: personalised only with `advertising` (without the TCF, `npa = 1` otherwise).
    @Published private(set) var personalisedAds = false
    /// An attribution SDK (AppsFlyer, Adjust…): started only with `advertising`.
    @Published private(set) var attributionStarted = false
    @Published private(set) var trackingStatus = "not asked"
    @Published private(set) var consentId: String?
    /// What an IAB TCF vendor (Google Mobile Ads…) reads in `UserDefaults.standard` when told of the choice: the CMP id,
    /// `gdprApplies`, the purpose consents and whether a TC string is there (CMP.md, « IAB TCF »).
    @Published private(set) var tcf = "none"
    @Published private(set) var tcfVendorLi = "-"

    /// Wired once, after `ScruterCMP.start`.
    func wire() {
        ScruterCMP.whenReady { [weak self] choice in
            self?.apply(choice)
            // Apple's prompt after the CMP, only when advertising is granted (CMP.md, ATT).
            ScruterCMP.requestTrackingIfGranted { status in self?.trackingStatus = Partners.name(status) }
        }
        ScruterCMP.onChange { [weak self] choice in self?.apply(choice) }
    }

    /// The IAB keys as a TCF vendor reads them.
    static func tcfKeys() -> String {
        let d = UserDefaults.standard
        guard let id = d.object(forKey: "IABTCF_CmpSdkID") as? Int else { return "none" }
        let tc = d.string(forKey: "IABTCF_TCString") ?? ""
        return "\(id)|\(d.integer(forKey: "IABTCF_gdprApplies"))|\(d.string(forKey: "IABTCF_PurposeConsents") ?? "-")|\(tc.isEmpty ? "-" : "tc")"
    }

    func refreshTcf() {
        let keys = Partners.tcfKeys()
        let vli = UserDefaults.standard.string(forKey: "IABTCF_VendorLegitimateInterests") ?? ""
        // Only a change redraws (UserDefaults notifies every write of the app).
        if keys != tcf { tcf = keys }
        if (vli.isEmpty ? "-" : vli) != tcfVendorLi { tcfVendorLi = vli.isEmpty ? "-" : vli }
    }

    private func apply(_ choice: ScruterCMP.Choice) {
        consentId = choice.consentId
        // Google Mobile Ads reads the TCF keys itself; they are written before the app hears of the choice.
        refreshTcf()
        // Firebase: Analytics.setAnalyticsCollectionEnabled(...) and Analytics.setConsent(...).
        analyticsStarted = choice.isGranted(.analytics)
        var signals: [String: String] = [:]
        for (k, v) in ScruterCMP.consentModeSignals() where [.adStorage, .adUserData, .adPersonalization, .analyticsStorage].contains(k) {
            signals[k.rawValue] = v.rawValue
        }
        consentMode = signals
        // Google Mobile Ads: GADRequest with extras ["npa": "1"] unless advertising is granted.
        personalisedAds = choice.isGranted(.advertising)
        // AppsFlyer / Adjust: start only with advertising; stop on a withdrawal.
        attributionStarted = choice.isGranted(.advertising)
    }

    static func name(_ s: ScruterCMP.TrackingStatus) -> String {
        switch s {
        case .notDetermined: return "not asked"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        }
    }
}

/// What the UI tests pass at launch: a local ingest, a fresh install, a dropped configuration cache.
enum Launch {
    static let arguments = ProcessInfo.processInfo.arguments

    static var endpoint: URL? {
        guard let i = arguments.firstIndex(of: "-cmp-endpoint"), i + 1 < arguments.count else { return nil }
        return URL(string: arguments[i + 1])
    }

    /// Runs before `ScruterCMP.start`.
    static func prepare() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScruterCMP")
        if arguments.contains("-cmp-fresh-install") {
            UserDefaults(suiteName: "net.scruter.cmp")?.removePersistentDomain(forName: "net.scruter.cmp")
            for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("IABTCF_") {
                UserDefaults.standard.removeObject(forKey: k)
            }
            try? fm.removeItem(at: support)
        }
        if arguments.contains("-cmp-drop-config") {
            try? fm.removeItem(at: support.appendingPathComponent("config.json"))
            try? fm.removeItem(at: support.appendingPathComponent("config-meta.json"))
        }
    }
}
