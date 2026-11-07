import Foundation

/// Element kinds (docs/MOBILE.md §3.5 step 2); `web` and `container` only in a team phone's element tree.
enum ElementKind: String {
    case button, link, input, choice, tab, cell, image, media, web, text, other, container
}

/// A node of a screen's element tree, as the identity algorithm sees it. UIKit views conform on iOS; tests use plain
/// objects.
protocol IdentityNode: AnyObject {
    var identityParent: IdentityNode? { get }
    var identityChildren: [IdentityNode] { get }
    /// `accessibilityIdentifier`, `scruterId`…: used when stable.
    var identityExplicit: String? { get }
    /// A cheap key of the node's type, compared before any string is built.
    var identityTypeKey: ObjectIdentifier { get }
    /// The type's name (`ProductCell`, `MyApp.ProductCell`, `_UIButtonBarButton`).
    var identityTypeName: String { get }
    var identityKind: ElementKind { get }
    /// The item position when the node is a list or grid item (flattened over sections), else nil.
    var identityItemIndex: Int? { get }
}

/// The identity algorithm, `IDENTITY_VERSION = 1` (docs/MOBILE.md §3.5): a selector (≤ 200 characters) and an index,
/// stable across launches and versions as long as the screen's structure is.
enum Identity {
    static let version = 1
    static let maxSelector = 200
    static let maxContext = 6

    /// Type names that say nothing about the element: they get `[kind]`.
    static let silentTypes: [String] = [
        "UIView", "UIStackView", "UIControl", "View", "ViewGroup", "LinearLayout", "FrameLayout", "RCTView",
        "UIHostingView", "HostingView", "PlatformViewHost", "_UIHostingView", "UITableViewCellContentView",
        "UICollectionViewCellContentView", "ScruterMarkerView",
    ]

    // MARK: Parts

    /// An explicit identifier is stable: starts with a letter, only `[A-Za-z0-9_.:-]`, ≤ 60 characters, no run of 5
    /// digits, not a UUID or a hex run of ≥ 8 (generated identifiers change between launches).
    static func isStable(_ id: String) -> Bool {
        let u = Array(id.utf8)
        guard !u.isEmpty, u.count <= 60, isLetter(u[0]) else { return false }
        var digits = 0
        var hexRun = 0
        var hexHasDigit = false
        var hexHasLetter = false
        for c in u {
            let allowed = isLetter(c) || isDigit(c) || c == 95 || c == 46 || c == 58 || c == 45
            guard allowed else { return false }
            digits = isDigit(c) ? digits + 1 : 0
            if digits >= 5 { return false }
            if isHex(c) {
                hexRun += 1
                if isDigit(c) { hexHasDigit = true } else { hexHasLetter = true }
                // A run of 8 hex characters mixing digits and letters (a word such as "deadbeef" alone is rare).
                if hexRun >= 8 && hexHasDigit && hexHasLetter { return false }
            } else {
                hexRun = 0
                hexHasDigit = false
                hexHasLetter = false
            }
        }
        return !looksLikeUUID(id)
    }

    private static func looksLikeUUID(_ s: String) -> Bool {
        let groups = s.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5, groups.map({ $0.count }) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.utf8.allSatisfy(isHex) }
    }

    private static func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    private static func isHex(_ c: UInt8) -> Bool { isDigit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) }

    /// A type name without generic arguments, module prefixes and leading `_`, ≤ 40 characters.
    static func cleanTypeName(_ raw: String) -> String {
        var s = raw
        if let lt = s.firstIndex(of: "<") { s = String(s[..<lt]) }
        if let dot = s.lastIndex(of: ".") { s = String(s[s.index(after: dot)...]) }
        while s.hasPrefix("_") { s.removeFirst() }
        s = s.filter { !$0.isWhitespace }
        if s.isEmpty { s = "View" }
        return Text.cut(s, max: 40)
    }

    /// The node's own part: `#id`, else its type name (plus `[kind]` when the type says nothing).
    static func part(of node: IdentityNode) -> String { Cache().part(node) }

    static func hasStableExplicit(_ node: IdentityNode) -> Bool {
        node.identityExplicit.map(isStable) ?? false
    }

    // MARK: Selector and index

    struct Result: Equatable {
        var selector: String
        var index: Int
    }

    /// Memoised parts, chains and subtrees for the identities of one screen state (a tap, a capture's strip): the
    /// algorithm compares many nodes, each part is built once.
    final class Cache {
        /// One entry per node and one per type (its clean name in `part`, `silent`): a single dictionary type.
        private final class Entry {
            var part: String?
            var silent = false
            var chain: [String]?
            var inItem: Bool?
            var subtree: [IdentityNode]?
        }

        private var entries: [ObjectIdentifier: Entry] = [:]

        init() {}

        private func entry(_ k: ObjectIdentifier) -> Entry {
            if let e = entries[k] { return e }
            let e = Entry()
            entries[k] = e
            return e
        }

        func part(_ n: IdentityNode) -> String {
            let e = entry(ObjectIdentifier(n))
            if let p = e.part { return p }
            let p: String
            if let id = n.identityExplicit, isStable(id) {
                p = "#" + id
            } else {
                // Per type, not per node: a screen holds thousands of views of a few types.
                let t = entry(n.identityTypeKey)
                if t.part == nil {
                    let raw = n.identityTypeName
                    let name = cleanTypeName(raw)
                    t.part = name
                    t.silent = silentTypes.contains(name) || silentTypes.contains(raw)
                }
                let name = t.part ?? ""
                p = t.silent ? name + "[" + n.identityKind.rawValue + "]" : name
            }
            e.part = p
            return p
        }

        /// Whether the node is, or sits inside, a list item (memoised along the ancestors).
        func inItem(_ n: IdentityNode, root: IdentityNode) -> Bool {
            let e = entry(ObjectIdentifier(n))
            if let v = e.inItem { return v }
            var v = false
            if n !== root {
                v = n.identityItemIndex != nil
                if !v, let p = n.identityParent { v = inItem(p, root: root) }
            }
            e.inItem = v
            return v
        }

        func chain(_ n: IdentityNode, root: IdentityNode) -> [String] {
            let e = entry(ObjectIdentifier(n))
            if let c = e.chain { return c }
            var out = [String]()
            var a = n.identityParent
            while let x = a, x !== root, out.count < 64 {
                out.append(part(x))
                a = x.identityParent
            }
            e.chain = out
            return out
        }

        func subtree(_ root: IdentityNode) -> [IdentityNode] {
            let e = entry(ObjectIdentifier(root))
            if let s = e.subtree { return s }
            let s = Identity.subtree(root)
            e.subtree = s
            return s
        }
    }

    /// The selector and index of `target` within the screen whose root is `root`.
    static func identify(_ target: IdentityNode, root: IdentityNode, cache: Cache = Cache()) -> Result {
        // A list or grid item, or an element inside one: the list's part + the item's part, the index is the item's
        // position (every item of the list shares the selector).
        if let (cell, list, item) = enclosingItem(of: target, root: root) {
            var parts = [cache.part(list), cache.part(cell)]
            if target !== cell {
                parts += contextParts(target, root: cell, population: cache.subtree(cell), cache: Cache())
            }
            return Result(selector: join(parts), index: max(0, min(9999, item)))
        }
        let population = cache.subtree(root)
        let parts = contextParts(target, root: root, population: population, cache: cache)
        let selector = join(parts)
        // Index: position among the screen's elements with the same selector, depth-first. An element has the same
        // selector when its own part and its nearest ancestors' parts (as many as the selector holds) are the same.
        let own = parts[parts.count - 1]
        let context = Array(parts.dropLast().reversed())
        let key = target.identityTypeKey
        var index = 0
        for node in population {
            if node === target { break }
            guard node.identityTypeKey == key, cache.part(node) == own, !cache.inItem(node, root: root) else { continue }
            if context.isEmpty || Array(cache.chain(node, root: root).prefix(context.count)) == context { index += 1 }
        }
        return Result(selector: selector, index: min(9999, index))
    }

    /// The parts of `target` with as much context as needed: while another element has the same selector and a
    /// different parent chain, prefix the nearest ancestor's part (≤ 6 levels, never above `root`); an ancestor with
    /// an explicit identifier ends the climb.
    static func contextParts(
        _ target: IdentityNode, root: IdentityNode, population: [IdentityNode], cache: Cache = Cache()
    ) -> [String] {
        let own = cache.part(target)
        var parts = [own]
        let targetChain = cache.chain(target, root: root)
        let key = target.identityTypeKey
        var others = population.filter { node in
            node !== target && node.identityTypeKey == key && cache.part(node) == own
        }.map { ($0, cache.chain($0, root: root)) }.filter { $0.1 != targetChain }
        var level = 0
        while !others.isEmpty && level < maxContext && level < targetChain.count {
            let p = targetChain[level]
            parts.insert(p, at: 0)
            if p.hasPrefix("#") { break }
            others = others.filter { level < $0.1.count && $0.1[level] == p }
            level += 1
        }
        return parts
    }

    /// Parts of the ancestors of `node`, nearest first, below `root`.
    static func chain(of node: IdentityNode, root: IdentityNode) -> [String] {
        Cache().chain(node, root: root)
    }

    /// The nearest list item at or above `node` (below `root`), its list and its position.
    static func enclosingItem(of node: IdentityNode, root: IdentityNode) -> (IdentityNode, IdentityNode, Int)? {
        var a: IdentityNode? = node
        var depth = 0
        while let n = a, n !== root, depth < 64 {
            if let item = n.identityItemIndex, let list = n.identityParent {
                // The list is the nearest ancestor of the cell (a table or collection view, a stack of items).
                return (n, list, item)
            }
            a = n.identityParent
            depth += 1
        }
        return nil
    }

    /// Depth-first nodes of a subtree (the root excluded), bounded.
    static func subtree(_ root: IdentityNode, limit: Int = 5000) -> [IdentityNode] {
        var out = [IdentityNode]()
        var stack = Array(root.identityChildren.reversed())
        while let n = stack.popLast(), out.count < limit {
            out.append(n)
            stack.append(contentsOf: n.identityChildren.reversed())
        }
        return out
    }

    /// Joined with `/`, ≤ 200 characters, cut at a `/` (the nearest context dropped first).
    static func join(_ parts: [String]) -> String {
        var p = parts
        var s = p.joined(separator: "/")
        while s.unicodeScalars.count > maxSelector && p.count > 1 {
            p.removeFirst()
            s = p.joined(separator: "/")
        }
        return Text.cut(s, max: maxSelector)
    }
}

/// Automatic screen names (docs/MOBILE.md §3.3): the type name without its conventional suffix; generics, module
/// prefixes and obfuscated names (1–3 characters) give no name.
enum ScreenName {
    static let suffixes = ["ViewController", "Controller", "VC", "Fragment", "Activity", "Screen", "Page"]
    static let maxLength = 120

    static func fromTypeName(_ raw: String) -> String? {
        if raw.contains("<") { return nil }
        var s = raw
        if let dot = s.lastIndex(of: ".") { s = String(s[s.index(after: dot)...]) }
        while s.hasPrefix("_") { s.removeFirst() }
        guard s.count > 3 else { return nil }
        guard s.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else { return nil }
        for suffix in suffixes where s.hasSuffix(suffix) && s.count > suffix.count {
            s = String(s.dropLast(suffix.count))
            break
        }
        return Text.clean(s, max: maxLength)
    }

    /// A name given by the app (`Scruter.screen`, `.scruterScreen`, `scruterScreenName`): ≤ 120 characters, trimmed,
    /// control characters removed; `nil` when nothing is left.
    static func explicit(_ name: String) -> String? {
        let n = Text.clean(name, max: maxLength)
        return n.isEmpty ? nil : n
    }
}
