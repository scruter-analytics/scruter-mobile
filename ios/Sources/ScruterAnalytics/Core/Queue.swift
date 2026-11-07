import Foundation

/// An item waiting to be sent: an event (`e`), an analysed screen view state (`x`) or a crash report (`cr`).
struct QueueItem {
    enum Kind: String { case event = "e", screenView = "x", crash = "cr" }

    var id: Int64
    var kind: Kind
    var session: String
    var time: Int64
    var body: JSON
    /// Bytes of `body`'s JSON, for the batch and queue limits.
    var bytes: Int

    init(id: Int64, kind: Kind, session: String, time: Int64, body: JSON) {
        self.id = id
        self.kind = kind
        self.session = session
        self.time = time
        self.body = body
        bytes = body.encoded().count
    }

    var line: JSON {
        ["i": .int(id), "k": .string(kind.rawValue), "s": .string(session), "t": .int(time), "b": body]
    }

    init?(line: JSON) {
        guard let id = line.int64("i"), let k = line.str("k").flatMap(Kind.init(rawValue:)),
            let s = line.str("s"), let t = line.int64("t"), let b = line["b"]
        else { return nil }
        self.init(id: id, kind: k, session: s, time: t, body: b)
    }
}

/// The persistent queue (docs/MOBILE.md §3.15): an append-only log in the app's private storage (`+` an item, `-` ids
/// removed), replayed at launch and compacted when it grows to twice the live data. Limits: 5 000 items or 5 MB, the
/// oldest dropped first; items older than 48 hours dropped; ≤ 10 crash reports.
final class PersistentQueue {
    static let maxItems = 5000
    static let maxBytes = 5 * 1024 * 1024
    static let maxAgeMs: Int64 = 48 * 3600 * 1000
    static let maxCrashes = 10

    private let store: FileStore
    private let file = "queue.log"
    private(set) var items: [QueueItem] = []
    private(set) var totalBytes = 0
    private var nextId: Int64 = 1
    private var pending = [UInt8]()
    private var logBytes = 0

    init(store: FileStore) {
        self.store = store
        load()
    }

    private func load() {
        guard let data = store.read(file) else { return }
        var live = [QueueItem]()
        var removed = Set<Int64>()
        var highest: Int64 = 0
        for raw in data.split(separator: 0x0A) where raw.count > 1 {
            let tag = raw[raw.startIndex]
            let rest = raw.dropFirst()
            if tag == UInt8(ascii: "+"), let j = JSON.parse(Data(rest)), let item = QueueItem(line: j) {
                // A newer state of an item replaces it in place (ids only grow: only an old id needs the search).
                if item.id <= highest, let i = live.lastIndex(where: { $0.id == item.id }) {
                    live[i] = item
                } else {
                    live.append(item)
                }
                highest = max(highest, item.id)
            } else if tag == UInt8(ascii: "-") {
                for part in String(decoding: rest, as: UTF8.self).split(separator: ",") {
                    if let id = Int64(part) { removed.insert(id) }
                }
            }
        }
        for item in live where !removed.contains(item.id) {
            items.append(item)
            totalBytes += item.bytes
        }
        nextId = highest + 1
        logBytes = data.count
        compact()
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var oldestTime: Int64? { items.first?.time }

    @discardableResult
    func append(kind: QueueItem.Kind, session: String, time: Int64, body: JSON) -> QueueItem {
        let item = QueueItem(id: nextId, kind: kind, session: session, time: time, body: body)
        nextId += 1
        if kind == .crash {
            let crashes = items.filter { $0.kind == .crash }
            if crashes.count >= PersistentQueue.maxCrashes, let first = crashes.first { remove(ids: [first.id]) }
        }
        items.append(item)
        totalBytes += item.bytes
        pending.append(UInt8(ascii: "+"))
        item.line.write(into: &pending)
        pending.append(0x0A)
        enforceLimits()
        return item
    }

    /// Replaces an unsent item's body in place (an analysed screen view's newer state).
    func replace(id: Int64, body: JSON, time: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        totalBytes -= items[i].bytes
        let item = QueueItem(id: id, kind: items[i].kind, session: items[i].session, time: time, body: body)
        items[i] = item
        totalBytes += item.bytes
        pending.append(UInt8(ascii: "+"))
        item.line.write(into: &pending)
        pending.append(0x0A)
    }

    func remove(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        var kept = [QueueItem]()
        kept.reserveCapacity(items.count)
        for item in items {
            if ids.contains(item.id) { totalBytes -= item.bytes } else { kept.append(item) }
        }
        if kept.count != items.count {
            items = kept
            var line = "-"
            for id in ids { line += String(id) + "," }
            pending.append(contentsOf: Array((line + "\n").utf8))
        }
    }

    /// Drops items older than 48 hours (the server could not place them any more, docs/MOBILE.md §2.1).
    func dropExpired(now: Int64) -> Int {
        let old = Set(items.filter { now - $0.time > PersistentQueue.maxAgeMs }.map { $0.id })
        remove(ids: old)
        return old.count
    }

    private func enforceLimits() {
        var drop = Set<Int64>()
        var n = items.count
        var bytes = totalBytes
        for item in items where n > PersistentQueue.maxItems || bytes > PersistentQueue.maxBytes {
            drop.insert(item.id)
            n -= 1
            bytes -= item.bytes
        }
        remove(ids: drop)
    }

    func clear() {
        items = []
        totalBytes = 0
        pending = []
        logBytes = 0
        store.remove(file)
    }

    /// Writes what changed since the last save (one append), compacting when the log is twice the live data.
    func save() {
        guard !pending.isEmpty else { return }
        store.append(file, Data(pending))
        logBytes += pending.count
        pending = []
        compact()
    }

    private func compact() {
        guard logBytes > 2 * totalBytes + 64 * 1024 || (items.isEmpty && logBytes > 0) else { return }
        if items.isEmpty {
            store.remove(file)
            logBytes = 0
            return
        }
        var out = [UInt8]()
        out.reserveCapacity(totalBytes + items.count * 40)
        for item in items {
            out.append(UInt8(ascii: "+"))
            item.line.write(into: &out)
            out.append(0x0A)
        }
        store.write(file, Data(out))
        logBytes = out.count
    }
}
