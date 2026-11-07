package net.scruter.internal

import org.json.JSONArray
import org.json.JSONObject

/**
 * Reads what a native crash or an ANR left in `ApplicationExitInfo` (docs/MOBILE.md §3.10) into a report's threads
 * and binary images: the tombstone protocol buffer of Android 12+ (`system/core/debuggerd/proto/tombstone.proto`,
 * decoded by a minimal wire-format reader: no protobuf dependency) and the text trace of an ANR.
 */
internal object Tombstone {
    class Frame(val relPc: Long, val pc: Long, val function: String?, val file: String?, val buildId: String?)
    class Thread(val id: Int, val name: String?, val frames: List<Frame>)
    class Parsed(
        val arch: Int,
        val pid: Int,
        val tid: Int,
        val signal: String?,
        val code: String?,
        val abort: String?,
        val threads: Map<Int, Thread>,
    )

    private class Reader(val b: ByteArray, var pos: Int, val end: Int) {
        fun more() = pos < end
        fun varint(): Long {
            var shift = 0
            var result = 0L
            while (pos < end) {
                val x = b[pos++].toInt()
                result = result or ((x and 0x7f).toLong() shl shift)
                if (x and 0x80 == 0) return result
                shift += 7
                if (shift > 63) break
            }
            throw IllegalArgumentException("bad varint")
        }
        fun bytes(): Reader {
            val n = varint().toInt()
            require(n >= 0 && pos + n <= end) { "bad length" }
            val r = Reader(b, pos, pos + n)
            pos += n
            return r
        }
        fun string(): String {
            val r = bytes()
            return String(b, r.pos, r.end - r.pos, Charsets.UTF_8)
        }
        fun skip(wire: Int) {
            when (wire) {
                0 -> varint()
                1 -> pos += 8
                2 -> bytes()
                5 -> pos += 4
                else -> throw IllegalArgumentException("bad wire type $wire")
            }
        }
    }

    fun parse(data: ByteArray): Parsed {
        val r = Reader(data, 0, data.size)
        var arch = 0
        var pid = 0
        var tid = 0
        var signal: String? = null
        var code: String? = null
        var abort: String? = null
        val threads = LinkedHashMap<Int, Thread>()
        while (r.more()) {
            val key = r.varint().toInt()
            val field = key ushr 3
            val wire = key and 7
            when {
                field == 1 && wire == 0 -> arch = r.varint().toInt()
                field == 5 && wire == 0 -> pid = r.varint().toInt()
                field == 6 && wire == 0 -> tid = r.varint().toInt()
                field == 10 && wire == 2 -> {
                    val s = r.bytes()
                    while (s.more()) {
                        val k = s.varint().toInt()
                        when {
                            k ushr 3 == 2 && k and 7 == 2 -> signal = s.string()
                            k ushr 3 == 4 && k and 7 == 2 -> code = s.string()
                            else -> s.skip(k and 7)
                        }
                    }
                }
                field == 14 && wire == 2 -> abort = r.string()
                field == 16 && wire == 2 -> {
                    val entry = r.bytes()
                    while (entry.more()) {
                        val k = entry.varint().toInt()
                        if (k ushr 3 == 2 && k and 7 == 2) {
                            val t = thread(entry.bytes())
                            threads[t.id] = t
                        } else {
                            entry.skip(k and 7)
                        }
                    }
                }
                else -> r.skip(wire)
            }
        }
        return Parsed(arch, pid, tid, signal, code, abort, threads)
    }

    private fun thread(r: Reader): Thread {
        var id = 0
        var name: String? = null
        val frames = ArrayList<Frame>()
        while (r.more()) {
            val k = r.varint().toInt()
            when {
                k ushr 3 == 1 && k and 7 == 0 -> id = r.varint().toInt()
                k ushr 3 == 2 && k and 7 == 2 -> name = r.string()
                k ushr 3 == 4 && k and 7 == 2 -> if (frames.size < 64) frames.add(frame(r.bytes())) else r.skip(2)
                else -> r.skip(k and 7)
            }
        }
        return Thread(id, name, frames)
    }

    private fun frame(r: Reader): Frame {
        var rel = 0L
        var pc = 0L
        var fn: String? = null
        var file: String? = null
        var build: String? = null
        while (r.more()) {
            val k = r.varint().toInt()
            when {
                k ushr 3 == 1 && k and 7 == 0 -> rel = r.varint()
                k ushr 3 == 2 && k and 7 == 0 -> pc = r.varint()
                k ushr 3 == 4 && k and 7 == 2 -> fn = r.string()
                k ushr 3 == 6 && k and 7 == 2 -> file = r.string()
                k ushr 3 == 8 && k and 7 == 2 -> build = r.string()
                else -> r.skip(k and 7)
            }
        }
        return Frame(rel, pc, fn, file, build)
    }

    private fun archName(arch: Int): String = when (arch) {
        0 -> "arm"
        1 -> "arm64"
        2 -> "x86"
        3 -> "x86_64"
        4 -> "riscv64"
        else -> "unknown"
    }

    private fun hex(v: Long): String = "0x" + java.lang.Long.toHexString(v)

    /** The `ex`, `th` and `img` of a native crash report from a parsed tombstone. */
    fun fill(report: JSONObject, t: Parsed, packageName: String) {
        val ex = JSONObject()
        ex.put("type", t.signal ?: "SIGNAL")
        t.code?.let { ex.put("code", Text.cut(it, 200)) }
        t.signal?.let { ex.put("sig", Text.cut(it, 20)) }
        Text.clean(t.abort, 200)?.let { ex.put("reason", it) }
        report.put("ex", ex)
        val images = LinkedHashMap<String, Int>()
        val img = JSONArray()
        val arch = archName(t.arch)
        fun frames(th: Thread): JSONArray {
            val out = JSONArray()
            for (f in th.frames) {
                val o = JSONObject()
                o.put("a", hex(f.pc))
                val file = f.file
                if (file != null) {
                    val key = file + "|" + (f.buildId ?: "")
                    var index = images[key]
                    if (index == null && images.size < 100) {
                        index = images.size
                        images[key] = index
                        val i = JSONObject().put("n", Text.cut(file.substring(file.lastIndexOf('/') + 1).ifEmpty { file }, 200))
                        f.buildId?.takeIf { it.isNotEmpty() }?.let { i.put("u", Text.cut(it, 100)) }
                        i.put("la", hex(f.pc - f.relPc))
                        i.put("ar", arch)
                        img.put(i)
                    }
                    if (index != null) o.put("i", index)
                    if (inApp(file, packageName)) o.put("ia", 1)
                }
                f.function?.takeIf { it.isNotEmpty() }?.let { o.put("fn", Text.cut(it, 200)) }
                out.put(o)
            }
            return out
        }
        val th = JSONArray()
        val crashed = t.threads[t.tid] ?: t.threads.values.firstOrNull()
        if (crashed != null) th.put(Crashes.thread(frames(crashed), crashed = true, main = crashed.id == t.pid))
        val main = t.threads[t.pid]
        if (main != null && main !== crashed) th.put(Crashes.thread(frames(main), crashed = false, main = true))
        if (th.length() == 0) th.put(Crashes.thread(JSONArray(), crashed = true, main = false))
        report.put("th", th)
        if (img.length() > 0) report.put("img", img)
    }

    fun inApp(file: String, packageName: String): Boolean =
        file.startsWith("/data/app/") && (file.contains(packageName) || file.contains("base.apk"))

    private val javaFrame = Regex("^\\s+at ([\\w$.<>-]+)\\.([\\w$<>-]+)\\((.*)\\)")
    private val nativeFrame = Regex("^\\s+native: #\\d+ pc ([0-9a-fA-F]+)\\s+(\\S+)(?: \\((.*?)\\+\\d+\\))?")

    /** The main thread's frames of an ANR trace (`ApplicationExitInfo.REASON_ANR`), ≤ 64. */
    fun anrFrames(trace: String, packageName: String): JSONArray {
        val out = JSONArray()
        var inMain = false
        for (line in trace.lineSequence()) {
            if (line.startsWith("\"main\"")) {
                inMain = true
                continue
            }
            if (!inMain) continue
            if (line.isBlank()) break
            if (out.length() >= 64) break
            val j = javaFrame.find(line)
            if (j != null) {
                val (cls, method, where) = j.destructured
                val file = where.substringBefore(':').takeIf { it.isNotEmpty() && !it.contains(' ') }
                val lineNo = where.substringAfter(':', "").toIntOrNull() ?: -1
                out.put(Crashes.javaFrame(cls, method, file, lineNo))
                continue
            }
            val n = nativeFrame.find(line)
            if (n != null) {
                val o = JSONObject()
                val file = n.groupValues[2]
                o.put("fl", Text.cut(file.substring(file.lastIndexOf('/') + 1), 200))
                n.groupValues[3].takeIf { it.isNotEmpty() }?.let { o.put("fn", Text.cut(it, 200)) }
                if (inApp(file, packageName)) o.put("ia", 1)
                out.put(o)
            }
        }
        return out
    }
}
