package net.scruter.internal

import android.os.Build
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.View
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.RadioButton
import android.widget.RatingBar
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import net.scruter.R
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference

/**
 * The forms of one screen view (docs/MOBILE.md §3.9): fields grouped by an explicit `scruterForm`, else by a
 * container whose explicit identifier ends with "form", else by the screen. Per field: focus count and time,
 * `changed`, errors — never a value, never its length, never a label. Passwords, one-time codes and payment fields are
 * ignored entirely. Caps: 10 forms of 40 fields.
 */
internal class Forms(private val screen: String) {
    class Field(val key: String, val type: String, val position: Int) {
        var focusCount = 0
        var focusMs = 0L
        var errors = 0
        var kinds = 0
        var changed = 0
        var focusSince = 0L
        var showsError = false
        var textHash = 0
        var ref: WeakReference<Any>? = null
    }

    class Form(val name: String, val index: Int) {
        var started = 0
        var sent = 0
        var refused = 0
        var firstFocus = 0L
        var fillMs = 0L
        var lastField: String? = null
        val fields = LinkedHashMap<String, Field>()
    }

    private val forms = LinkedHashMap<String, Form>()
    private val byRef = java.util.WeakHashMap<Any, Pair<Form, Field>>()
    private val bySemantics = HashMap<Int, Pair<Form, Field>>()
    private var focused: Pair<Form, Field>? = null
    var dirty = false
        private set

    val isEmpty: Boolean get() = forms.isEmpty()

    /** Finds the fields of [tree] (at the screen view's start, at focus changes). */
    fun scan(tree: UiTree, onField: (View) -> Unit) {
        val positions = HashMap<String, Int>()
        for (n in tree.nodes) {
            if (!isField(n)) continue
            val src = n.source ?: continue
            if (byRef.containsKey(src) || src !is View && bySemantics.containsKey(semanticsId(src))) continue
            if (sensitive(n)) continue
            val formName = formOf(n)
            val form = forms[formName] ?: if (forms.size < 10) Form(formName, forms.size).also { forms[formName] = it; dirty = true } else continue
            if (form.fields.size >= 40) continue
            val position = positions[formName] ?: form.fields.size
            positions[formName] = position + 1
            val type = type(n)
            val key = key(n, type, position)
            val field = form.fields[key] ?: Field(key, type, position).also { form.fields[key] = it; dirty = true }
            field.ref = WeakReference(src)
            if (src is View) {
                byRef[src] = Pair(form, field)
                onField(src)
            } else {
                bySemantics[semanticsId(src)] = Pair(form, field)
                field.textHash = ComposeNodes.textHash(src)
            }
        }
    }

    private fun semanticsId(src: Any): Int = if (Optional.compose) ComposeNodes.id(src) else 0

    private fun isField(n: UiNode): Boolean {
        val src = n.source
        return if (src is View) {
            ViewNodes.isTextInput(src) || src is CompoundButton || src is Spinner || src is SeekBar || src is RatingBar
        } else {
            Optional.compose && ComposeNodes.isField(src)
        }
    }

    private fun formOf(n: UiNode): String {
        var x: UiNode? = n
        while (x != null) {
            x.form?.let { return it }
            x = x.parent
        }
        x = n.parent
        while (x != null) {
            if (x.explicit && x.part.lowercase().endsWith("form")) return Text.cut(x.part.substring(1), 120)
            x = x.parent
        }
        return screen
    }

    private fun sensitive(n: UiNode): Boolean {
        if (n.explicit && Text.isSensitiveName(n.part)) return true
        val v = n.source
        if (v is TextView) {
            val t = v.inputType
            val variation = t and InputType.TYPE_MASK_VARIATION
            val cls = t and InputType.TYPE_MASK_CLASS
            if (cls == InputType.TYPE_CLASS_TEXT && (variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD || variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)
            ) return true
            if (cls == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD) return true
            if (v.transformationMethod is android.text.method.PasswordTransformationMethod) return true
            if (Build.VERSION.SDK_INT >= 26) {
                v.autofillHints?.forEach { h ->
                    val l = h.lowercase()
                    if ("password" in l || "creditcard" in l || "otp" in l || "security" in l || Text.isSensitiveName(h)) return true
                }
            }
        } else if (v != null && v !is View && ComposeNodes.isPassword(v)) {
            return true
        }
        return false
    }

    private fun type(n: UiNode): String {
        val v = n.source
        if (v !is View) return ComposeNodes.fieldType(v)
        return when (v) {
            is Switch -> "switch"
            is CheckBox -> "checkbox"
            is RadioButton -> "radio"
            is CompoundButton -> if (v.javaClass.name.contains("Switch")) "switch" else "choice"
            is Spinner -> "select"
            is SeekBar, is RatingBar -> "slider"
            is TextView -> {
                val t = v.inputType
                when (t and InputType.TYPE_MASK_CLASS) {
                    InputType.TYPE_CLASS_NUMBER -> "number"
                    InputType.TYPE_CLASS_PHONE -> "phone"
                    InputType.TYPE_CLASS_DATETIME -> "date"
                    else -> when (t and InputType.TYPE_MASK_VARIATION) {
                        InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS -> "email"
                        InputType.TYPE_TEXT_VARIATION_URI -> "url"
                        InputType.TYPE_TEXT_VARIATION_POSTAL_ADDRESS -> "address"
                        InputType.TYPE_TEXT_VARIATION_PERSON_NAME -> "name"
                        else -> if (t and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0) "textarea" else "text"
                    }
                }
            }
            else -> "choice"
        }
    }

    /** §3.9: the explicit identifier, else the autofill hint, else `type:position`. */
    private fun key(n: UiNode, type: String, position: Int): String {
        if (n.explicit) return Text.cut(n.part.substring(1), 100)
        val v = n.source
        if (v is View && Build.VERSION.SDK_INT >= 26) {
            v.autofillHints?.firstOrNull { Text.isStableId(it) }?.let { return Text.cut(it, 100) }
        }
        return "$type:$position"
    }

    private fun find(src: Any?): Pair<Form, Field>? = when (src) {
        null -> null
        is View -> byRef[src]
        else -> bySemantics[semanticsId(src)]
    }

    /** Focus moved to [src] (a View or a semantics node), or away from every field (null). */
    fun focus(src: Any?, now: Long) {
        val next = find(src)
        val prev = focused
        if (prev === next || prev != null && next != null && prev.second === next.second) return
        if (prev != null) {
            blur(prev, now)
        }
        focused = next
        if (next != null) {
            val (form, field) = next
            field.focusCount++
            field.focusSince = now
            if (form.started == 0) {
                form.started = 1
                form.firstFocus = now
            }
            form.lastField = field.key
            dirty = true
        }
    }

    private fun blur(p: Pair<Form, Field>, now: Long) {
        val field = p.second
        if (field.focusSince > 0) field.focusMs += now - field.focusSince
        field.focusSince = 0
        checkError(field)
        dirty = true
    }

    /** An edit of a field (a text watcher, a choice tapped, a Compose text that changed). */
    fun changed(src: Any?) {
        val f = find(src) ?: return
        if (f.second.changed == 0) {
            f.second.changed = 1
            dirty = true
        }
    }

    /** Compose: compares each field's text fingerprint (in memory only) and its focus. */
    fun refreshCompose(tree: UiTree, now: Long) {
        var focusedNode: Any? = null
        for (n in tree.nodes) {
            val src = n.source ?: continue
            if (src is View) continue
            val f = bySemantics[semanticsId(src)] ?: continue
            f.second.ref = WeakReference(src)
            val h = ComposeNodes.textHash(src)
            if (h != f.second.textHash) {
                f.second.textHash = h
                changed(src)
            }
            if (ComposeNodes.focused(src)) focusedNode = src
        }
        if (focusedNode != null || focused?.second?.ref?.get() !is View) focus(focusedNode, now)
    }

    private fun checkError(field: Field): Boolean {
        val src = field.ref?.get()
        val error = when (src) {
            is TextView -> src.error != null || Optional.material && Material.hasError(src)
            null -> false
            is View -> false
            else -> ComposeNodes.hasError(src)
        }
        if (error && !field.showsError) {
            field.errors++
            field.kinds = field.kinds or INVALID
            dirty = true
        }
        field.showsError = error
        return error
    }

    /** A button of the screen was tapped: a submit attempt refused when a field then shows an error. */
    fun submitAttempt() {
        for (form in forms.values) {
            if (form.started == 0 || form.sent == 1) continue
            var refused = false
            for (f in form.fields.values) if (checkError(f)) refused = true
            if (refused) {
                form.refused++
                dirty = true
            }
        }
    }

    /** `Scruter.fieldError(key, kind)`. */
    fun explicitError(key: String, kind: Int) {
        for (form in forms.values) {
            val f = form.fields[key] ?: continue
            f.errors++
            f.kinds = f.kinds or kind
            dirty = true
        }
    }

    /** `Scruter.formSent(name)`, or the automatic rule at a forward navigation. */
    fun sent(name: String?, now: Long) {
        for (form in forms.values) {
            if (name != null && form.name != name || form.sent == 1) continue
            form.sent = 1
            if (form.firstFocus > 0) form.fillMs = now - form.firstFocus
            dirty = true
        }
    }

    /** §3.9: leaving the screen forward after a field changed, with no field showing an error, sends the form. */
    fun leaveForward(now: Long) {
        focused?.let { blur(it, now) }
        focused = null
        for (form in forms.values) {
            if (form.sent == 1 || form.fields.values.none { it.changed == 1 }) continue
            if (form.fields.values.any { checkError(it) }) continue
            sent(form.name, now)
        }
    }

    fun leave(now: Long) {
        focused?.let { blur(it, now) }
        focused = null
    }

    fun toJson(): JSONArray {
        dirty = false
        val out = JSONArray()
        for (form in forms.values) {
            val o = JSONObject()
            o.put("s", form.name)
            o.put("i", form.index)
            o.put("v", 1)
            o.put("b", form.started)
            o.put("ok", form.sent)
            o.put("rf", form.refused)
            o.put("ms", form.fillMs.coerceIn(0, 86_400_000))
            form.lastField?.let { o.put("lf", it) }
            val fd = JSONArray()
            for (f in form.fields.values) {
                val ms = f.focusMs + if (f.focusSince > 0) android.os.SystemClock.elapsedRealtime() - f.focusSince else 0
                fd.put(JSONArray().put(f.key).put(Text.cut(f.type, 30)).put(0).put(f.position.coerceIn(0, 255))
                    .put(f.focusCount.coerceAtMost(65_535)).put(ms.coerceIn(0, 86_400_000)).put(f.errors.coerceAtMost(65_535))
                    .put(f.kinds and 15).put(f.changed))
            }
            o.put("fd", fd)
            out.put(o)
        }
        return out
    }

    companion object {
        const val REQUIRED = 1
        const val FORMAT = 2
        const val REFUSED = 4
        const val INVALID = 8

        /** Watches a text input for edits: only the fact that an edit happened, never the text. */
        fun watch(v: View, onEdit: (View) -> Unit) {
            if (v !is EditText || v.getTag(R.id.scruter_watched) == true) return
            v.setTag(R.id.scruter_watched, true)
            v.addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    onEdit(v)
                }
            })
        }
    }
}
