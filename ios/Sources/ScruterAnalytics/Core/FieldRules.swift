import Foundation

/// Which form fields are never measured (docs/MOBILE.md §3.9): passwords, one-time codes and payment fields are
/// ignored entirely, whatever the app's identifiers say.
enum FieldRules {
    /// `textContentType` values (UIKit raw values) that mark a secret or a payment field.
    static let sensitiveContentTypes = [
        "password", "new-password", "one-time-code", "cc-number", "cc-csc", "cc-exp", "cc-exp-month", "cc-exp-year",
        "cc-name", "cc-given-name", "cc-family-name", "cc-additional-name", "cc-type",
        // Raw values as some SDK versions spell them.
        "newPassword", "oneTimeCode", "creditCardNumber", "creditCardSecurityCode", "creditCardExpiration",
        "creditCardExpirationMonth", "creditCardExpirationYear", "creditCardName", "creditCardGivenName",
        "creditCardFamilyName", "creditCardMiddleName", "creditCardType",
    ]

    static let sensitiveWords = ["card", "cvc", "cvv", "iban", "pin", "otp", "token", "secret", "password", "passwd"]

    static func isSensitive(secure: Bool, contentType: String?, names: [String?]) -> Bool {
        if secure { return true }
        if let t = contentType, sensitiveContentTypes.contains(t) || t.lowercased().contains("creditcard")
            || t.hasPrefix("cc-")
        {
            return true
        }
        for case let n? in names {
            let l = n.lowercased()
            if sensitiveWords.contains(where: { l.contains($0) }) { return true }
        }
        return false
    }

    /// The field key from the autofill content type (`postalCode`, `emailAddress`…): UIKit's raw values are
    /// `postal-code`-like on recent systems; both spellings give the camel-case key.
    static func key(fromContentType raw: String) -> String {
        guard raw.contains("-") else { return raw }
        let parts = raw.split(separator: "-")
        guard let first = parts.first else { return raw }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}
