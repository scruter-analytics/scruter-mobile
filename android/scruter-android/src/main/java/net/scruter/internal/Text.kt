package net.scruter.internal

import java.security.SecureRandom

/** String rules shared by every path of the SDK: limits are counted in code points, like the JSON Schemas. */
internal object Text {
    private val random by lazy { SecureRandom() }
    private val hexDigits = "0123456789abcdef".toCharArray()
    private val sensitive = arrayOf("card", "cvc", "cvv", "iban", "pin", "otp", "token", "secret", "password", "passwd")

    /** Removes control characters, trims, and cuts to [max] code points (`null` when nothing is left). */
    fun clean(value: String?, max: Int): String? {
        if (value == null) return null
        val out = StringBuilder(minOf(value.length, max * 2))
        var i = 0
        while (i < value.length) {
            val cp = value.codePointAt(i)
            i += Character.charCount(cp)
            if (Character.isISOControl(cp) || Character.getType(cp) == Character.FORMAT.toInt()) continue
            out.appendCodePoint(cp)
        }
        val trimmed = out.toString().trim()
        if (trimmed.isEmpty()) return null
        return cut(trimmed, max)
    }

    /** The first [max] code points of [value]. */
    fun cut(value: String, max: Int): String {
        if (value.length <= max) return value
        if (value.codePointCount(0, value.length) <= max) return value
        return value.substring(0, value.offsetByCodePoints(0, max))
    }

    /** docs/MOBILE.md §3.5: an explicit identifier is used only when it is stable across launches and versions. */
    fun isStableId(id: String?): Boolean {
        if (id == null || id.isEmpty() || id.length > 60 || !isLetter(id[0])) return false
        var digits = 0
        var hex = 0
        for (c in id) {
            val digit = c in '0'..'9'
            if (!digit && !isLetter(c) && c != '_' && c != '.' && c != ':' && c != '-') return false
            digits = if (digit) digits + 1 else 0
            hex = if (digit || c in 'a'..'f' || c in 'A'..'F') hex + 1 else 0
            if (digits >= 5 || hex >= 8) return false
        }
        return true
    }

    private fun isLetter(c: Char) = c in 'a'..'z' || c in 'A'..'Z'

    /** Field names that mean a secret (docs/MOBILE.md §3.9): such fields are ignored entirely. */
    fun isSensitiveName(name: String?): Boolean = name != null && sensitive.any { name.contains(it, ignoreCase = true) }

    /** `*` wildcards, the remote configuration's ignored screens (`xs`). */
    fun matches(name: String, pattern: String): Boolean {
        val parts = pattern.split('*')
        if (parts.size == 1) return name == pattern
        if (!name.startsWith(parts[0])) return false
        var at = parts[0].length
        for (p in 1 until parts.size - 1) {
            val found = name.indexOf(parts[p], at)
            if (found < 0) return false
            at = found + parts[p].length
        }
        val last = parts[parts.size - 1]
        return name.length - at >= last.length && name.endsWith(last)
    }

    fun hex(bytes: ByteArray): String {
        val out = CharArray(bytes.size * 2)
        for (i in bytes.indices) {
            val v = bytes[i].toInt() and 0xff
            out[i * 2] = hexDigits[v ushr 4]
            out[i * 2 + 1] = hexDigits[v and 0x0f]
        }
        return String(out)
    }

    /** [bytes] random bytes as lower-case hex. */
    fun randomHex(bytes: Int): String {
        val b = ByteArray(bytes)
        random.nextBytes(b)
        return hex(b)
    }

    /** A screen-view number: random, 1 … 2^53 − 1. */
    fun randomViewNumber(): Long = (random.nextLong() ushr 11).coerceAtLeast(1L)

    fun randomDouble(): Double = random.nextDouble()

    /**
     * The automatic screen name of a type (docs/MOBILE.md §3.3): the simple name without its conventional suffix;
     * `null` for an obfuscated name (1–3 characters, R8) or nothing left.
     */
    fun screenNameOf(type: Class<*>): String? {
        var name = type.name
        name = name.substring(name.lastIndexOf('.') + 1)
        name = name.substring(name.lastIndexOf('$') + 1)
        if (name.length <= 3) return null
        for (suffix in arrayOf("Activity", "Fragment", "Screen", "Page", "Controller")) {
            if (name.length > suffix.length && name.endsWith(suffix)) {
                name = name.substring(0, name.length - suffix.length)
                break
            }
        }
        return clean(name, 120)
    }

    /** A type's part of a selector (docs/MOBILE.md §3.5): simple name, leading `_` removed, ≤ 40 characters. */
    fun typePart(type: Class<*>): String? {
        var t: Class<*>? = type
        while (t != null) {
            var name = t.name
            name = name.substring(name.lastIndexOf('.') + 1)
            name = name.substring(name.lastIndexOf('$') + 1).trimStart('_')
            if (name.length > 3 && name.firstOrNull()?.isLetter() == true) return cut(name, 40)
            t = t.superclass
        }
        return null
    }
}
