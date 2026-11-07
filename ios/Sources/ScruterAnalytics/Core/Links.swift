import Foundation

/// Links that open the app (docs/MOBILE.md §3.13). The server keeps only the host, the path and the `utm_*` values;
/// the SDK already drops everything else before the URL leaves the phone (a token in a link never travels), and replaces
/// the path's personal segments (the server does it again, whatever a client sends).
enum Links {
    /// What stands for a personal segment of a path.
    static let masked = ":id"

    /// A segment that is not a word of the app's: an e-mail address, a number, a UUID, an opaque token (docs/MOBILE.md
    /// §3.13; the same rule as the server's and Android's, with the same table in their tests). Bytes and plain loops: this
    /// runs on every link, and generic collection code costs the binary size of docs/MOBILE.md §3.18.
    static func isPersonal(_ segment: [UInt8]) -> Bool {
        if segment.isEmpty { return false }
        var chars = 0, digits = 0, hex = 0, dashes = 0, run = 0
        var runHasDigit = false
        var long = false
        for b in segment {
            if b & 0xC0 != 0x80 { chars += 1 }
            if b == 64 { return true }  // @
            let digit = b >= 48 && b <= 57
            let lower = b | 0x20
            let letter = lower >= 97 && lower <= 122
            if digit { digits += 1 }
            if b == 45 { dashes += 1 } else if digit || (lower >= 97 && lower <= 102) { hex += 1 }
            if digit || letter {
                run += 1
                runHasDigit = runHasDigit || digit
                if run >= 32 || (run >= 16 && runHasDigit) { long = true }
            } else {
                run = 0
                runHasDigit = false
            }
        }
        return long || chars > 64 || digits == segment.count || digits >= 6 || (hex == 32 && hex + dashes == segment.count)
    }

    /// A decoded path with its personal segments replaced.
    static func maskedPath(_ path: String) -> String {
        var out = [UInt8]()
        var segment = [UInt8]()
        for b in path.utf8 {
            if b == 47 {
                if isPersonal(segment) { out += Array(masked.utf8) } else { out += segment }
                out.append(47)
                segment.removeAll(keepingCapacity: true)
            } else {
                segment.append(b)
            }
        }
        if isPersonal(segment) { out += Array(masked.utf8) } else { out += segment }
        return String(decoding: out, as: UTF8.self)
    }

    /// `scheme://host/path?utm_…` of a link, ≤ 2 000 characters; the `scruter_open` marker removed.
    static func sanitize(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        c.user = nil
        c.password = nil
        c.fragment = nil
        c.path = maskedPath(c.path)
        // A custom scheme's host is the app's first word, not a server: `app://jane@x.com`.
        let scheme = c.scheme?.lowercased()
        if scheme != "http", scheme != "https", let host = c.host, isPersonal(Array(host.utf8)) {
            c.host = "id"
        }
        let utm = (c.queryItems ?? []).filter { $0.name.lowercased().hasPrefix("utm_") }
        c.queryItems = utm.isEmpty ? nil : utm
        return Text.cut(c.string ?? "", max: 2000)
    }

    /// The opening a URL stands for: `widget` / `shortcut` / `notification` when the app marks it with
    /// `scruter_open=…` (a widget's `widgetURL`, a quick action's URL), else `link`.
    static func openingKind(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let v = items.first(where: { $0.name == "scruter_open" })?.value,
            ["widget", "shortcut", "notification", "other"].contains(v)
        {
            return v
        }
        return "link"
    }

    /// The team-phone registration link of the QR code: `scruter-<app id lower-case>://team?t=scr_qr_…`.
    static func registrationToken(_ url: URL, appId: String) -> String? {
        guard url.scheme?.lowercased() == "scruter-" + appId.lowercased(), url.host == "team",
            let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?
                .value,
            StartOptions.isValidRegistrationToken(t)
        else { return nil }
        return t
    }

    /// The app's own team-phone scheme (never an opening).
    static func isTeamScheme(_ url: URL, appId: String) -> Bool {
        url.scheme?.lowercased() == "scruter-" + appId.lowercased()
    }
}

/// The question a phone asks before it becomes a team phone (docs/MOBILE.md §3.12): the SDK has no strings of its own.
struct TeamPrompt {
    var title: String
    var message: String
    var add: String
    var cancel: String

    /// `language` is the phone's first language (`fr-FR`).
    static func text(language: String, app: String) -> TeamPrompt {
        if language.hasPrefix("fr") {
            return TeamPrompt(
                title: "Ajouter ce téléphone à l’équipe de \(app)\u{00A0}?",
                message:
                    "Ce téléphone prendra des images des écrans de \(app) pour son équipe, et son usage ne comptera plus dans les statistiques. Refusez si vous n’en faites pas partie.",
                add: "Ajouter", cancel: "Annuler")
        }
        if language.hasPrefix("de") {
            return TeamPrompt(
                title: "Dieses Telefon zum Team von \(app) hinzufügen?",
                message:
                    "Dieses Telefon nimmt dann Bilder der Bildschirme von \(app) für das Team auf, und seine Nutzung zählt nicht mehr in den Statistiken. Lehnen Sie ab, wenn Sie nicht zum Team gehören.",
                add: "Hinzufügen", cancel: "Abbrechen")
        }
        return TeamPrompt(
            title: "Add this phone to the \(app) team?",
            message:
                "This phone will take pictures of \(app)’s screens for its team, and its use will no longer count in the statistics. Decline if you are not part of it.",
            add: "Add", cancel: "Cancel")
    }
}
