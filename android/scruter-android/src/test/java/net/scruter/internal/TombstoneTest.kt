package net.scruter.internal

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.ByteArrayOutputStream

/** Native crashes and ANRs read from ApplicationExitInfo (docs/MOBILE.md §3.10). */
@RunWith(RobolectricTestRunner::class)
class TombstoneTest {
    /** A minimal protocol buffer writer, to build tombstones as debuggerd does. */
    private class Pb {
        val out = ByteArrayOutputStream()
        fun varint(v: Long): Pb {
            var x = v
            while (x and 0x7fL.inv() != 0L) {
                out.write(((x and 0x7f) or 0x80).toInt())
                x = x ushr 7
            }
            out.write(x.toInt())
            return this
        }
        fun tag(field: Int, wire: Int) = varint(((field shl 3) or wire).toLong())
        fun int(field: Int, v: Long) = tag(field, 0).varint(v)
        fun bytes(field: Int, b: ByteArray): Pb {
            tag(field, 2).varint(b.size.toLong())
            out.write(b)
            return this
        }
        fun str(field: Int, s: String) = bytes(field, s.toByteArray())
        fun msg(field: Int, m: Pb) = bytes(field, m.out.toByteArray())
        fun fixed64(field: Int, v: Long): Pb {
            tag(field, 1)
            for (i in 0 until 8) out.write(((v ushr (8 * i)) and 0xff).toInt())
            return this
        }
    }

    private fun frame(rel: Long, pc: Long, fn: String?, file: String, build: String) =
        Pb().int(1, rel).int(2, pc).int(3, 0x7ffd0000).also { if (fn != null) it.str(4, fn) }.int(5, 4).str(6, file).int(7, 0).str(8, build)

    @Test
    fun parsesATombstone() {
        val app = "/data/app/~~x==/fr.ateliermona.app-y==/base.apk!lib/arm64-v8a/libmona.so"
        val crashed = Pb().int(1, 4242).str(2, "RenderThread")
            .msg(3, Pb().str(1, "x0").int(2, 1)) // a register: skipped
            .msg(4, frame(0x1234, 0x7a00001234, null, app, "aabbccdd00112233"))
            .msg(4, frame(0x5678, 0x7b00005678, "abort", "/apex/com.android.runtime/lib64/bionic/libc.so", "ffee"))
        val main = Pb().int(1, 4000).str(2, "main")
            .msg(4, frame(0x10, 0x7c00000010, "__epoll_pwait", "/apex/com.android.runtime/lib64/bionic/libc.so", "ffee"))
        val t = Pb().int(1, 1).str(2, "google/husky/husky:15/AP4A").int(5, 4000).int(6, 4242)
            .msg(10, Pb().int(1, 11).str(2, "SIGSEGV").int(3, 1).str(4, "SEGV_MAPERR").fixed64(9, 0))
            .str(14, "Abort message for jane@example.com")
            .msg(16, Pb().int(1, 4242).msg(2, crashed))
            .msg(16, Pb().int(1, 4000).msg(2, main))
            .msg(17, Pb().str(1, "ignored mapping"))
        val parsed = Tombstone.parse(t.out.toByteArray())
        assertEquals(4000, parsed.pid)
        assertEquals(4242, parsed.tid)
        assertEquals("SIGSEGV", parsed.signal)
        assertEquals(2, parsed.threads.size)

        val r = JSONObject().put("s", "9c1b2d3e4f5a6b7c").put("id", "a1b2c3d4e5f60718").put("t", 1_762_345_678_901L)
            .put("k", "crash").put("src", "native")
        Tombstone.fill(r, parsed, "fr.ateliermona.app")
        assertEquals("SIGSEGV", r.getJSONObject("ex").getString("type"))
        assertEquals("SEGV_MAPERR", r.getJSONObject("ex").getString("code"))
        val th = r.getJSONArray("th")
        assertEquals(2, th.length())
        val first = th.getJSONObject(0).getJSONArray("f").getJSONObject(0)
        assertEquals("0x7a00001234", first.getString("a"))
        assertEquals(1, first.getInt("ia"))
        val img = r.getJSONArray("img")
        assertEquals("libmona.so", img.getJSONObject(0).getString("n"))
        assertEquals("aabbccdd00112233", img.getJSONObject(0).getString("u"))
        assertEquals("0x7a00000000", img.getJSONObject(0).getString("la"))
        assertEquals("arm64", img.getJSONObject(0).getString("ar"))
        assertEquals(1, th.getJSONObject(1).getInt("m"))
        Conformance.crash("tombstone", r)
    }

    @Test
    fun parsesAnAnrTrace() {
        val trace = """
            ----- pid 4000 at 2026-11-05 10:00:00.000 -----
            Cmd line: fr.ateliermona.app

            "Signal Catcher" daemon prio=10 tid=2 Runnable
              at java.lang.Object.wait(Native method)

            "main" prio=5 tid=1 Sleeping
              | group="main" sCount=1 ucsCount=0 flags=1 obj=0x72c3e1f8 self=0xb400007a5c47c380
              native: #00 pc 000000000004e0d4  /apex/com.android.runtime/lib64/bionic/libc.so (__epoll_pwait+4) (BuildId: 1234)
              at java.lang.Thread.sleep(Native method)
              at fr.ateliermona.app.CartActivity.onResume(CartActivity.kt:42)
              at android.app.Activity.performResume(Activity.java:8000)

            "RenderThread" prio=7 tid=3 Native
              at x.y.z(Unknown Source:3)
        """.trimIndent()
        val f = Tombstone.anrFrames(trace, "fr.ateliermona.app")
        assertEquals(4, f.length())
        assertEquals("__epoll_pwait", f.getJSONObject(0).getString("fn"))
        val app = f.getJSONObject(2)
        assertEquals("fr.ateliermona.app.CartActivity", app.getString("cl"))
        assertEquals("onResume", app.getString("fn"))
        assertEquals("CartActivity.kt", app.getString("fl"))
        assertEquals(42, app.getInt("l"))
        assertEquals(1, app.getInt("ia"))
        assertFalse(f.getJSONObject(3).has("ia"))
        assertTrue(f.getJSONObject(1).getString("cl") == "java.lang.Thread")
    }
}
