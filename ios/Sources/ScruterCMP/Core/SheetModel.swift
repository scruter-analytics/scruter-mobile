import Foundation

/// Everything the sheet draws, resolved by the engine (language, variant, texts, words, colours, media URLs): the views
/// read it and call back with a decision; they never read the configuration.
/// A class: the views and the engine share one copy (a struct this size costs the app its copying code).
final class SheetModel {
    enum Kind: Equatable {
        /// The first layer and its Personnaliser steps (§2.2, §2.3): no dismissal but by its buttons.
        case banner
        /// The app's settings entry (§2.5): every purpose, the receipt, withdrawal; closable.
        case preferences
    }

    struct Purpose {
        var key: String
        var name: String
        var description: String
        var providers: [String]
    }

    let kind: Kind
    let lang: String
    let rtl: Bool
    /// The texts as drawn (French spacing applied), and the hash of the texts as stored: the proof's `h`.
    let texts: Texts
    let hash: String
    let words: Words
    /// `light`, `dark` or `auto`.
    let theme: String
    let color: String
    /// `three` buttons, or `two` (« Personnaliser » | « Tout accepter », only with the band's « Continuer sans accepter »).
    let twoButtons: Bool
    /// The header band with « Certifié par Scruter » and « Continuer sans accepter ».
    let closeLink: Bool
    /// The Free plan: « Proposé par Scruter » under the buttons when there is no band.
    let branding: Bool
    let hero: HeroUi?
    let noPanel: Bool
    /// The app's icon (`logo_mode: auto`) or the uploaded logo, astride the media.
    let logoURL: String?
    let logoIsIcon: Bool
    let policyURL: String?
    /// The optional purposes, in the banner's order: the steps and the preferences' switches.
    let purposes: [Purpose]
    /// The required purposes (« Toujours actif »).
    let required: [Purpose]
    /// The switches' initial states: what the visitor granted (nothing is pre-ticked).
    let granted: Set<String>
    /// The receipt in the preferences.
    let consentId: String?
    let decidedAt: Int64?
    /// The variant drawn for this opening (`b` during an A/B test, else `a` or nothing): the proof's banner.
    let banner: Int
    /// The IAB TCF layers (§6), when the site's TCF is on and the vendor list could be read.
    let tcf: TcfSheet?

    init(
        kind: Kind,
        lang: String,
        rtl: Bool,
        texts: Texts,
        hash: String,
        words: Words,
        theme: String,
        color: String,
        twoButtons: Bool,
        closeLink: Bool,
        branding: Bool,
        hero: HeroUi?,
        noPanel: Bool,
        logoURL: String?,
        logoIsIcon: Bool,
        policyURL: String?,
        purposes: [Purpose],
        required: [Purpose],
        granted: Set<String>,
        consentId: String?,
        decidedAt: Int64?,
        banner: Int,
        tcf: TcfSheet? = nil
    ) {
        self.kind = kind
        self.lang = lang
        self.rtl = rtl
        self.texts = texts
        self.hash = hash
        self.words = words
        self.theme = theme
        self.color = color
        self.twoButtons = twoButtons
        self.closeLink = closeLink
        self.branding = branding
        self.hero = hero
        self.noPanel = noPanel
        self.logoURL = logoURL
        self.logoIsIcon = logoIsIcon
        self.policyURL = policyURL
        self.purposes = purposes
        self.required = required
        self.granted = granted
        self.consentId = consentId
        self.decidedAt = decidedAt
        self.banner = banner
        self.tcf = tcf
    }

    /// The Personnaliser steps: one per optional purpose, then the partners with the TCF (board M15, 2).
    var stepCount: Int { purposes.count + (tcf != nil ? 1 : 0) }

    static let certifiedURL = "https://scruter.net/cmp?utm_source=cmp_app&utm_medium=referral&utm_campaign=certified_by_scruter"

    /// « Étape n sur N ».
    @_optimize(size) func stepOf(_ n: Int, _ total: Int) -> String { SheetModel.stepOf(words, n, total) }

    @_optimize(size) static func stepOf(_ words: Words, _ n: Int, _ total: Int) -> String {
        words.stepOf.replacingOccurrences(of: "{n}", with: String(n)).replacingOccurrences(of: "{t}", with: String(total))
    }
}

/// What the sheet answers.
struct SheetDecision: Equatable {
    /// `nil`: « Enregistrer » (the action follows from the switches).
    var action: CMPAction?
    /// Every optional purpose's state.
    var granted: Set<String>
    var source: CMPSource
    /// « Enregistrer » with the TCF layers: their switches (untouched ones follow the banner purposes); `nil` for « Tout
    /// accepter », « Tout refuser » and without the TCF, which say it all.
    var tcf: TcfChoice? = nil
}
