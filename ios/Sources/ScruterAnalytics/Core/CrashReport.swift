import Foundation

/// Crash reports (docs/MOBILE.md §3.10, docs/API.md §5.3 `cr`): the raw report the signal / Mach / exception handlers
/// write at the crash (`ScruterCrash`, async-signal-safe), MetricKit's diagnostics, and their conversion into the
/// batch's `cr` items. Never a log line, never a property value: breadcrumbs are screen and event names only.
enum CrashReport {
    static let maxFrames = 64
    static let maxImages = 100
    static let maxBreadcrumbs = 10

    struct Image {
        var name: String
        var uuid: String
        var load: UInt64
        var size: UInt64
        var arch: String
        var inApp: Bool
    }

    struct Thread {
        var crashed: Bool
        var main: Bool
        var addresses: [UInt64]
    }

    struct Raw {
        var time: Int64 = 0
        var kind = "crash"
        var type = ""
        var code = ""
        var signal = ""
        var reason = ""
        var context: JSON = .object(Fields())
        var threads: [Thread] = []
        var images: [Image] = []
    }

    // MARK: The raw report of ScruterCrash

    /// Parses the text report written at the crash (format of `ScruterCrash/crash.c`); nil when it is empty, cut
    /// before its threads, or not a report.
    static func parseRaw(_ data: Data) -> Raw? {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        guard lines[0].hasPrefix("SCRUTER-CRASH 1") else { return nil }
        var raw = Raw()
        for line in lines.dropFirst() {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<space])
            let value = String(line[line.index(after: space)...])
            switch key {
            case "time": raw.time = Int64(value) ?? 0
            case "kind": raw.kind = value == "anr" || value == "nonfatal" ? value : "crash"
            case "type": raw.type = value
            case "code": raw.code = value
            case "sig": raw.signal = value
            case "reason": raw.reason = value
            case "ctx": raw.context = JSON.parse(value) ?? .object(Fields())
            case "thread":
                let flags = value.components(separatedBy: " ")
                raw.threads.append(Thread(crashed: flags[0] == "1", main: flags.count > 1 && flags[1] == "1", addresses: []))
            case "f":
                let last = raw.threads.count - 1
                if let a = hexValue(value), last >= 0, raw.threads[last].addresses.count < maxFrames {
                    raw.threads[last].addresses.append(a)
                }
            case "img":
                // Load address, size, UUID, architecture, in the app, then the name (which may hold spaces).
                let f = value.components(separatedBy: " ")
                if f.count >= 6, let load = hexValue(f[0]), let size = hexValue(f[1]) {
                    raw.images.append(
                        Image(
                            name: f[5...].joined(separator: " "), uuid: f[2].uppercased(), load: load, size: size,
                            arch: f[3], inApp: f[4] == "1"))
                }
            default: break
            }
        }
        guard raw.time > 0, raw.threads.contains(where: { !$0.addresses.isEmpty }) else { return nil }
        return raw
    }

    static func hexValue(_ s: String) -> UInt64? {
        let t = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        return UInt64(t, radix: 16)
    }

    static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

    /// The `cr` item of a raw report, for session `session` (from the report's context when nil).
    static func item(from raw: Raw, id: String = Random.hex(bytes: 8)) -> JSON? {
        guard let session = raw.context.str("s"), session.count == 16 else { return nil }
        var used = [Int]()
        func imageIndex(_ a: UInt64) -> Int? {
            guard let i = raw.images.firstIndex(where: { a >= $0.load && a < $0.load &+ $0.size }) else { return nil }
            if let pos = used.firstIndex(of: i) { return pos }
            guard used.count < maxImages else { return nil }
            used.append(i)
            return used.count - 1
        }
        var threads = [JSON]()
        let ordered = raw.threads.filter { $0.crashed } + raw.threads.filter { !$0.crashed }
        for t in ordered.prefix(2) where !t.addresses.isEmpty {
            let frames: [JSON] = t.addresses.prefix(maxFrames).map { a in
                var f: Fields = ["a": .string(hex(a))]
                if let i = imageIndex(a) {
                    f["i"] = .int(Int64(i))
                    f["ia"] = .int(raw.images[used[i]].inApp ? 1 : 0)
                }
                return .object(f)
            }
            threads.append(["c": .int(t.crashed ? 1 : 0), "m": .int(t.main ? 1 : 0), "f": .array(frames)])
        }
        guard !threads.isEmpty else { return nil }
        let images: [JSON] = used.map { i in
            let im = raw.images[i]
            return [
                "n": .string(Text.cut(im.name, max: 200)), "u": .string(Text.cut(im.uuid, max: 100)),
                "la": .string(hex(im.load)), "ar": .string(Text.cut(im.arch, max: 20)),
            ]
        }
        var ex: Fields = [:]
        if !raw.type.isEmpty { ex["type"] = .string(Text.cut(raw.type, max: 200)) }
        if !raw.code.isEmpty { ex["code"] = .string(Text.cut(raw.code, max: 200)) }
        if !raw.signal.isEmpty { ex["sig"] = .string(Text.cut(raw.signal, max: 20)) }
        if !raw.reason.isEmpty { ex["reason"] = .string(Text.clean(raw.reason, max: 200)) }
        var o: Fields = [
            "s": .string(session), "id": .string(id), "t": .int(raw.time), "k": .string(raw.kind), "src": "native",
            "ex": .object(ex), "th": .array(threads), "img": .array(images),
        ]
        let crumbs = (raw.context.list("bc") ?? []).compactMap(Breadcrumb.init(json:)).suffix(maxBreadcrumbs)
        o["bc"] = .array(crumbs.map { $0.json })
        o["scr"] = .string(Text.cut(raw.context.str("scr") ?? "", max: 120))
        o["fg"] = .int(raw.context.int("fg") == 0 ? 0 : 1)
        if let launch = raw.context.int64("lt"), raw.time >= launch { o["up"] = .int(raw.time - launch) }
        return .object(o)
    }

    // MARK: MetricKit

    struct Diagnostic {
        /// `crash` or `anr` (a hang ≥ 2 s).
        var kind: String
        var time: Int64
        /// MetricKit's `callStackTree.jsonRepresentation()`, parsed.
        var callStackTree: JSON
        var exceptionType: Int?
        var exceptionCode: Int?
        var signal: Int?
        var reason: String?
    }

    /// The `cr` item of a MetricKit diagnostic, attributed to `session` with its breadcrumbs and screen.
    static func item(
        from d: Diagnostic, session: String, screen: String, breadcrumbs: [Breadcrumb], inApp: (String) -> Bool,
        id: String = Random.hex(bytes: 8)
    ) -> JSON? {
        let stacks = d.callStackTree.list("callStacks") ?? []
        let attributed = stacks.first { $0.flag("threadAttributed") } ?? stacks.first
        guard let stack = attributed, let root = stack.list("callStackRootFrames")?.first else { return nil }
        var images = [Image]()
        var frames = [JSON]()
        var frame: JSON? = root
        while let f = frame, frames.count < maxFrames {
            guard let address = f.int64("address").map({ UInt64(bitPattern: $0) }) else { break }
            var out: Fields = ["a": .string(hex(address))]
            if let uuid = f.str("binaryUUID"), let offset = f.int64("offsetIntoBinaryTextSegment") {
                let name = f.str("binaryName") ?? "?"
                let load = address &- UInt64(bitPattern: offset)
                var index = images.firstIndex { $0.uuid == uuid.uppercased() }
                if index == nil && images.count < maxImages {
                    images.append(
                        Image(name: name, uuid: uuid.uppercased(), load: load, size: 0, arch: "", inApp: inApp(name)))
                    index = images.count - 1
                }
                if let i = index {
                    out["i"] = .int(Int64(i))
                    out["ia"] = .int(images[i].inApp ? 1 : 0)
                }
            }
            frames.append(.object(out))
            frame = f.list("subFrames")?.first
        }
        guard !frames.isEmpty else { return nil }
        var ex: Fields = [:]
        if let t = d.exceptionType { ex["type"] = .string(machExceptionName(t)) }
        if let c = d.exceptionCode { ex["code"] = .string(String(c)) }
        if let s = d.signal { ex["sig"] = .string(signalName(s)) }
        if let r = d.reason, !r.isEmpty { ex["reason"] = .string(Text.clean(r, max: 200)) }
        if d.kind == "anr" && ex["type"] == nil { ex["type"] = "Hang" }
        return .object([
            "s": .string(session), "id": .string(id), "t": .int(d.time), "k": .string(d.kind), "src": "native",
            "ex": .object(ex),
            "th": .array([["c": 1, "m": .int(d.kind == "anr" ? 1 : 0), "f": .array(frames)]]),
            "img": .array(
                images.map {
                    ["n": .string(Text.cut($0.name, max: 200)), "u": .string($0.uuid), "la": .string(hex($0.load))]
                }),
            "bc": .array(breadcrumbs.suffix(maxBreadcrumbs).map { $0.json }),
            "scr": .string(Text.cut(screen, max: 120)), "fg": 1,
        ])
    }

    static func machExceptionName(_ t: Int) -> String {
        switch t {
        case 1: return "EXC_BAD_ACCESS"
        case 2: return "EXC_BAD_INSTRUCTION"
        case 3: return "EXC_ARITHMETIC"
        case 4: return "EXC_EMULATION"
        case 5: return "EXC_SOFTWARE"
        case 6: return "EXC_BREAKPOINT"
        case 10: return "EXC_CRASH"
        case 11: return "EXC_RESOURCE"
        case 12: return "EXC_GUARD"
        default: return "EXC_\(t)"
        }
    }

    static func signalName(_ s: Int) -> String {
        switch s {
        case 4: return "SIGILL"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 8: return "SIGFPE"
        case 9: return "SIGKILL"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 13: return "SIGPIPE"
        default: return "SIG\(s)"
        }
    }

    // MARK: De-duplication

    /// The report's signature for de-duplication: kind + the first five in-app frames (image UUID + offset), else
    /// the first five frames — what the server's raw signature uses (docs/MOBILE.md §6.6).
    static func signature(_ item: JSON) -> String {
        let images = item.list("img") ?? []
        let threads = item.list("th") ?? []
        let crashed = threads.first { $0.int("c") == 1 } ?? threads.first
        let frames = crashed?.list("f") ?? []
        func key(_ f: JSON) -> String {
            guard let a = f.str("a").flatMap(hexValue) else { return "?" }
            if let i = f.int("i"), i < images.count, let u = images[i].str("u"),
                let la = images[i].str("la").flatMap(hexValue)
            {
                return u + "+" + String(a &- la, radix: 16)
            }
            return String(a, radix: 16)
        }
        let inApp = frames.filter { $0.int("ia") == 1 }
        let chosen = (inApp.isEmpty ? frames : inApp).prefix(5)
        return (item.str("k") ?? "") + "|" + chosen.map(key).joined(separator: ",")
    }

    /// Two reports are the same crash when their times are within ± 2 s and their signatures match.
    static func isDuplicate(_ a: JSON, of b: JSON) -> Bool {
        guard a["k"] == b["k"], let ta = a.int64("t"), let tb = b.int64("t") else { return false }
        return abs(ta - tb) <= 2000 && signature(a) == signature(b)
    }
}
