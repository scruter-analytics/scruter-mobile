import Foundation
import XCTest

@testable import ScruterAnalytics

/// A plain tree for the identity algorithm.
final class Node: IdentityNode {
    let type: String
    let explicit: String?
    let kind: ElementKind
    let item: Int?
    weak var parent: Node?
    var children: [Node] = []

    init(_ type: String, id: String? = nil, kind: ElementKind = .other, item: Int? = nil, _ children: [Node] = []) {
        self.type = type
        explicit = id
        self.kind = kind
        self.item = item
        self.children = children
        for c in children { c.parent = self }
    }

    var identityParent: IdentityNode? { parent }
    var identityChildren: [IdentityNode] { children }
    var identityExplicit: String? { explicit }
    var identityTypeKey: ObjectIdentifier { ObjectIdentifier(Node.key(type)) }
    var identityTypeName: String { type }
    var identityKind: ElementKind { kind }
    var identityItemIndex: Int? { item }

    private static var keys: [String: KeyBox] = [:]
    final class KeyBox {}
    static func key(_ t: String) -> KeyBox {
        if let k = keys[t] { return k }
        let k = KeyBox()
        keys[t] = k
        return k
    }
}

final class IdentityTests: XCTestCase {
    func testStableIdentifiers() {
        XCTAssertTrue(Identity.isStable("add_to_cart"))
        XCTAssertTrue(Identity.isStable("checkout.pay-button:1"))
        XCTAssertFalse(Identity.isStable("1abc"), "starts with a letter")
        XCTAssertFalse(Identity.isStable("item12345"), "no run of 5 digits")
        XCTAssertFalse(Identity.isStable("a@b"))
        XCTAssertFalse(Identity.isStable("cell-3f2a9c1e"), "a hex run of 8")
        XCTAssertFalse(Identity.isStable("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        XCTAssertFalse(Identity.isStable(String(repeating: "a", count: 61)))
        XCTAssertFalse(Identity.isStable("with space"))
    }

    func testParts() {
        XCTAssertEqual(Identity.cleanTypeName("MyApp.ProductCell"), "ProductCell")
        XCTAssertEqual(Identity.cleanTypeName("_UIButtonBarButton"), "UIButtonBarButton")
        XCTAssertEqual(Identity.cleanTypeName("Wrapper<Int>"), "Wrapper")
        XCTAssertEqual(Identity.part(of: Node("UIButton", kind: .button)), "UIButton")
        XCTAssertEqual(Identity.part(of: Node("UIView", kind: .button)), "UIView[button]")
        XCTAssertEqual(Identity.part(of: Node("UIButton", id: "add_to_cart", kind: .button)), "#add_to_cart")
        XCTAssertEqual(Identity.part(of: Node("UIButton", id: "btn-7a8b9c0d1e", kind: .button)), "UIButton")
    }

    func testContextOnlyWhenNeeded() {
        let buy = Node("UIButton", kind: .button)
        let share = Node("UIButton", kind: .button)
        let back = Node("UIButton", kind: .button)
        let header = Node("HeaderView", [back])
        let footer = Node("FooterView", [Node("UIStackView", [buy, share])])
        let root = Node("UIView", [header, footer])
        XCTAssertEqual(Identity.identify(back, root: root), .init(selector: "HeaderView/UIButton", index: 0))
        // Siblings with the same parent chain share the selector: the index tells them apart.
        XCTAssertEqual(Identity.identify(buy, root: root), .init(selector: "UIStackView[other]/UIButton", index: 0))
        XCTAssertEqual(Identity.identify(share, root: root), .init(selector: "UIStackView[other]/UIButton", index: 1))
        let lone = Node("UISwitch", kind: .choice)
        let root2 = Node("UIView", [Node("A", [lone])])
        XCTAssertEqual(Identity.identify(lone, root: root2), .init(selector: "UISwitch", index: 0))
    }

    func testExplicitAncestorEndsTheClimb() {
        let img1 = Node("UIImageView", kind: .image)
        let img2 = Node("UIImageView", kind: .image)
        let root = Node("UIView", [Node("UIScrollView", id: "gallery", [Node("Wrap", [img1])]), Node("Other", [Node("Wrap", [img2])])])
        XCTAssertEqual(Identity.identify(img1, root: root).selector, "#gallery/Wrap/UIImageView")
        XCTAssertEqual(Identity.identify(img2, root: root).selector, "Other/Wrap/UIImageView")
    }

    func testListItemsShareTheirSelector() {
        let cells = (0..<3).map { i in Node("ProductCell", kind: .cell, item: i + 10, [Node("UIButton", kind: .button)]) }
        let list = Node("UITableView", id: "products", cells)
        let root = Node("UIView", [list])
        XCTAssertEqual(Identity.identify(cells[2], root: root), .init(selector: "#products/ProductCell", index: 12))
        XCTAssertEqual(Identity.identify(cells[1].children[0], root: root), .init(selector: "#products/ProductCell/UIButton", index: 11))
    }

    func testSelectorLengthIsCutAtASlash() {
        let parts = (0..<30).map { "Part\($0)Name" }
        let s = Identity.join(parts)
        XCTAssertLessThanOrEqual(s.count, 200)
        XCTAssertTrue(s.hasSuffix("Part29Name"))
        XCTAssertFalse(s.hasPrefix("/"))
    }

    func testIdentityOnALargeScreenIsFast() {
        var rows = [Node]()
        for i in 0..<400 {
            rows.append(Node("RowView", [Node("UILabel", kind: .text), Node("UIButton", id: i % 2 == 0 ? nil : "buy", kind: .button), Node("UIImageView", kind: .image), Node("UIView")]))
        }
        let root = Node("UIView", [Node("UIStackView", rows)])
        let target = rows[399].children[1]
        let start = Date()
        let r = Identity.identify(target, root: root)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r.selector, "#buy")
        XCTAssertEqual(r.index, 199)
        // §3.18 budget: ≤ 0.5 ms on a phone for 2 000 elements; a debug build on a CI machine gets 50 ms of slack.
        XCTAssertLessThan(elapsed, 0.05)
    }
}

final class RulesTests: XCTestCase {
    func testScreenNames() {
        XCTAssertEqual(ScreenName.fromTypeName("ProductViewController"), "Product")
        XCTAssertEqual(ScreenName.fromTypeName("AtelierMona.CheckoutPage"), "Checkout")
        XCTAssertEqual(ScreenName.fromTypeName("ProductScreen"), "Product")
        XCTAssertEqual(ScreenName.fromTypeName("SettingsVC"), "Settings")
        XCTAssertNil(ScreenName.fromTypeName("UIHostingController<ContentView>"))
        XCTAssertNil(ScreenName.fromTypeName("a.b"))
        XCTAssertNil(ScreenName.fromTypeName("Abc"), "obfuscated: 1–3 characters")
        XCTAssertEqual(ScreenName.explicit("  Cart\u{0007}  "), "Cart")
        XCTAssertNil(ScreenName.explicit("   "))
        XCTAssertEqual(ScreenName.explicit(String(repeating: "é", count: 200))?.count, 120)
    }

    func testDaysMatchTheCalendar() {
        for name in ["Europe/Paris", "America/Los_Angeles", "Pacific/Kiritimati", "UTC"] {
            let zone = TimeZone(identifier: name)!
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            // Every 7 hours over four years, leap day and clock changes included.
            var ms: Int64 = 1_704_067_200_000
            while ms < 1_830_000_000_000 {
                let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(ms) / 1000))
                XCTAssertEqual(Day.string(ms: ms, zone: zone), String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!))
                ms += 7 * 3_600_000
            }
        }
    }

    func testWildcards() {
        XCTAssertTrue(Text.wildcard("Debug*", matches: "DebugMenu"))
        XCTAssertTrue(Text.wildcard("*Test*", matches: "ATestB"))
        XCTAssertFalse(Text.wildcard("Debug*", matches: "debugMenu"))
        XCTAssertTrue(Text.wildcard("Cart", matches: "Cart"))
        XCTAssertFalse(Text.wildcard("Cart", matches: "Carts"))
    }

    func testSensitiveFields() {
        XCTAssertTrue(FieldRules.isSensitive(secure: true, contentType: nil, names: []))
        XCTAssertTrue(FieldRules.isSensitive(secure: false, contentType: "one-time-code", names: []))
        XCTAssertTrue(FieldRules.isSensitive(secure: false, contentType: "cc-number", names: []))
        XCTAssertTrue(FieldRules.isSensitive(secure: false, contentType: nil, names: ["cardNumber"]))
        XCTAssertTrue(FieldRules.isSensitive(secure: false, contentType: nil, names: [nil, "IBAN"]))
        XCTAssertFalse(FieldRules.isSensitive(secure: false, contentType: "postal-code", names: ["zip"]))
        XCTAssertEqual(FieldRules.key(fromContentType: "postal-code"), "postalCode")
        XCTAssertEqual(FieldRules.key(fromContentType: "emailAddress"), "emailAddress")
    }

    func testCurrencies() {
        XCTAssertEqual(Currency.minorUnits(34.0, currency: "EUR"), 3400)
        XCTAssertEqual(Currency.minorUnits(1200, currency: "JPY"), 1200)
        XCTAssertEqual(Currency.minorUnits(1.5, currency: "KWD"), 1500)
        XCTAssertFalse(Currency.isValid("eur"))
    }

    func testGzipIsValid() {
        let data = Data((0..<5000).map { UInt8($0 % 251) })
        let gz = Gzip.compress(data)
        XCTAssertEqual(Gunzip.body(gz, gzip: true), data)
        XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testRegistrationLinks() {
        let url = URL(string: "scruter-atmona02://team?t=scr_qr_" + String(repeating: "A", count: 32))!
        XCTAssertNotNil(Links.registrationToken(url, appId: "ATMONA02"))
        XCTAssertNil(Links.registrationToken(url, appId: "OTHER01"))
        XCTAssertNil(Links.registrationToken(URL(string: "scruter-atmona02://team?t=bad")!, appId: "ATMONA02"))
        XCTAssertTrue(StartOptions.isValidAppId("ATMONA02"))
        XCTAssertFalse(StartOptions.isValidAppId("atmona02"))
        XCTAssertTrue(StartOptions.isValidDebugKey("scr_dbg_" + String(repeating: "x", count: 43)))
    }
}
