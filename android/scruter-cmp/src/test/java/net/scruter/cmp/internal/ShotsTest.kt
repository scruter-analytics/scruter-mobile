package net.scruter.cmp.internal

import android.app.Activity
import android.app.Dialog
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.view.View
import android.widget.Button
import net.scruter.cmp.ConsentState
import net.scruter.cmp.ScruterCMP
import net.scruter.cmp.ui.JoinedRow
import org.json.JSONArray
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowDialog
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs

/**
 * Screenshot tests of the sheet (docs/CMP-MOBILE.md §9.2): each layer, light and dark, phone and tablet, French, German,
 * Arabic, 200 % font scale. Each image is written to `build/screenshots` and compared with its golden copy in
 * `src/test/screenshots` when there is one (`-Pscruter.recordShots=true` records them); the layout rules are checked on
 * every shot: targets of 48 dp, « Tout refuser » as wide as « Tout accepter », the sheet on the screen.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w393dp-h852dp-xxhdpi")
class ShotsTest {
    private lateinit var server: FakeIngest

    @Before
    fun setUp() {
        Sdk.wipe()
        server = FakeIngest()
        // Apps declare android:supportsRtl="true" (the default of a new project): the sheet mirrors for Arabic.
        Sdk.app.applicationInfo.flags = Sdk.app.applicationInfo.flags or android.content.pm.ApplicationInfo.FLAG_SUPPORTS_RTL
    }

    @After
    fun tearDown() {
        Sdk.stop()
        server.close()
        RuntimeEnvironment.setFontScale(1f)
    }

    private enum class Layer { FIRST, STEP, LAST_STEP, PREFERENCES, PARTNERS, VENDOR, TCF_PREFERENCES }

    private fun shot(name: String, layer: Layer, theme: String = "light", lang: String? = null, tablet: Boolean = false, scale: Float = 1f, video: Boolean = false, tcf: Boolean = false) {
        if (tablet) RuntimeEnvironment.setQualifiers("sw834dp-w834dp-h1194dp-xhdpi")
        if (scale != 1f) RuntimeEnvironment.setFontScale(scale)
        // The IAB TCF layers (boards M7 and M15): the kit's configuration with the TCF and its GVL 186 vendors.
        if (tcf) server.config = server.goldenTcf()
        server.edit { o ->
            val ui = o.getJSONObject("config").getJSONObject("ui")
            ui.put("theme", theme)
            ui.put("languages", JSONArray(listOf("fr", "en", "de", "ar")))
            ui.put("rtl", JSONArray(listOf("ar")))
            ui.getJSONObject("texts").getJSONObject("fr").put("kicker", "Avant de commencer")
            if (video) {
                val hero = ui.getJSONObject("hero")
                hero.put("type", "video")
                hero.put("video", JSONArray().put(org.json.JSONObject().put("url", "${server.url}/cmp/media/loop.mp4").put("type", "video/mp4; codecs=\"avc1.64001f\"").put("w", 960)))
            }
        }
        server.packs["de"] = FakeIngest.pack("de")
        server.packs["ar"] = FakeIngest.pack("ar")
        Sdk.start(server)
        ScruterCMP.setLanguage(lang)
        val controller = Robolectric.buildActivity(TestActivity::class.java).setup()
        val activity = controller.get()
        var dialog = waitSheet()
        when (layer) {
            Layer.FIRST -> Unit
            Layer.STEP -> clickMiddle(dialog)
            Layer.LAST_STEP -> {
                clickMiddle(dialog)
                clickMiddle(dialog)
            }
            Layer.PREFERENCES, Layer.TCF_PREFERENCES -> {
                Views.all(dialog.window!!.decorView).filterIsInstance<Button>().last().performClick()
                Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
                Sdk.until(what = "closed") { ScruterCMP.engine()?.ui?.current() == null }
                ScruterCMP.showPreferences(activity)
                dialog = waitSheet()
            }
            Layer.PARTNERS, Layer.VENDOR -> {
                repeat(3) {
                    clickMiddle(dialog)
                    dialog = ShadowDialog.getLatestDialog()
                }
                if (layer == Layer.VENDOR) {
                    Views.all(dialog.window!!.decorView).first { it.tag == "scruter-cmp-vendor-755" }.performClick()
                    Sdk.idle(200)
                }
            }
        }
        Sdk.idle(600)
        check(name, activity, dialog)
    }

    private fun waitSheet(): Dialog {
        Sdk.until(what = "the sheet") { ScruterCMP.engine()?.ui?.current()?.isShowing == true }
        Sdk.idle(600)
        return ShadowDialog.getLatestDialog()
    }

    private fun clickMiddle(d: Dialog) {
        val row = Views.all(d.window!!.decorView).filterIsInstance<JoinedRow>().single()
        val buttons = Views.all(row).filterIsInstance<Button>()
        buttons[buttons.size / 2].performClick()
        Sdk.idle(200)
    }

    private fun check(name: String, activity: Activity, dialog: Dialog) {
        val decor = dialog.window!!.decorView
        val density = decor.resources.displayMetrics.density
        // Every target of the sheet is 48 dp high at least (docs/CMP-MOBILE.md §3.12).
        for (b in Views.all(decor).filter { it.isClickable && !(it is android.widget.TextView && it.isTextSelectable) && it.visibility == View.VISIBLE && it.isShown && it.width > 0 && it !is android.widget.FrameLayout && it !is android.widget.LinearLayout }) {
            assertTrue("$name: ${b.javaClass.simpleName} \"${(b as? android.widget.TextView)?.text}\" is ${b.height / density} dp high", b.height >= (48 * density).toInt() - 1)
        }
        // « Tout refuser » is never smaller than « Tout accepter ».
        val row = Views.all(decor).filterIsInstance<JoinedRow>().single()
        val buttons = Views.all(row).filterIsInstance<Button>()
        if (!row.column) assertTrue("$name: equal parts", buttons.all { abs(it.width - buttons.last().width) <= 2 })
        else assertTrue("$name: a column, each part on the whole width", buttons.all { abs(it.width - buttons.first().width) <= 2 })
        // The sheet stays on the screen.
        val card = (decor.findViewById<android.view.ViewGroup>(android.R.id.content).getChildAt(0) as android.view.ViewGroup).getChildAt(1)
        val loc = IntArray(2)
        card.getLocationOnScreen(loc)
        assertTrue("$name: the sheet's top is on the screen", loc[1] >= 0)
        assertTrue("$name: the sheet's bottom is on the screen", loc[1] + card.height <= decor.height + 1)
        save(name, render(activity, dialog))
    }

    private fun render(activity: Activity, dialog: Dialog): Bitmap {
        val a = activity.window.decorView
        val d = dialog.window!!.decorView
        val bmp = Bitmap.createBitmap(d.width, d.height, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.drawColor(Color.WHITE)
        a.draw(c)
        d.draw(c)
        return bmp
    }

    private fun save(name: String, bmp: Bitmap) {
        val out = File(System.getProperty("scruter.shotsOut") ?: "build/screenshots").apply { mkdirs() }
        FileOutputStream(File(out, "$name.png")).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
        // Golden copies at half size: enough to see a layout change, a quarter of the bytes in the repository.
        val half = Bitmap.createScaledBitmap(bmp, bmp.width / 2, bmp.height / 2, true)
        // The golden copy as this run would record it (`golden/`, in the CI's artifact): a new shot's reference.
        File(out, "golden").apply { mkdirs() }.let { d -> FileOutputStream(File(d, "$name.png")).use { half.compress(Bitmap.CompressFormat.PNG, 100, it) } }
        val goldenDir = File(System.getProperty("scruter.shotsGolden") ?: "src/test/screenshots")
        val golden = File(goldenDir, "$name.png")
        if (System.getProperty("scruter.recordShots") == "true") {
            goldenDir.mkdirs()
            FileOutputStream(golden).use { half.compress(Bitmap.CompressFormat.PNG, 100, it) }
            return
        }
        if (!golden.isFile) return
        val g = android.graphics.BitmapFactory.decodeFile(golden.path)
        assertEquals("$name: size", g.width to g.height, half.width to half.height)
        var diff = 0
        for (y in 0 until half.height) for (x in 0 until half.width) if (!close(half.getPixel(x, y), g.getPixel(x, y))) diff++
        val share = diff / (half.width.toDouble() * half.height)
        assertTrue("$name differs from its golden copy on ${"%.2f".format(share * 100)} % of the pixels", share < 0.01)
    }

    private fun close(a: Int, b: Int): Boolean =
        abs(Color.red(a) - Color.red(b)) < 24 && abs(Color.green(a) - Color.green(b)) < 24 && abs(Color.blue(a) - Color.blue(b)) < 24

    @Test fun firstLayerPhoneLight() = shot("fr-phone-light-1-first", Layer.FIRST)

    @Test fun stepPhoneLight() = shot("fr-phone-light-2-step", Layer.STEP)

    @Test fun lastStepPhoneLight() = shot("fr-phone-light-3-last-step", Layer.LAST_STEP)

    @Test fun preferencesPhoneLight() = shot("fr-phone-light-4-preferences", Layer.PREFERENCES)

    @Test fun firstLayerPhoneDark() = shot("fr-phone-dark-1-first", Layer.FIRST, theme = "dark")

    @Test fun stepPhoneDark() = shot("fr-phone-dark-2-step", Layer.STEP, theme = "dark")

    @Test fun lastStepPhoneDark() = shot("fr-phone-dark-3-last-step", Layer.LAST_STEP, theme = "dark")

    @Test fun preferencesPhoneDark() = shot("fr-phone-dark-4-preferences", Layer.PREFERENCES, theme = "dark")

    @Test fun firstLayerTabletLight() = shot("fr-tablet-light-1-first", Layer.FIRST, tablet = true)

    @Test fun stepTabletLight() = shot("fr-tablet-light-2-step", Layer.STEP, tablet = true)

    @Test fun preferencesTabletLight() = shot("fr-tablet-light-4-preferences", Layer.PREFERENCES, tablet = true)

    @Test fun firstLayerTabletDark() = shot("fr-tablet-dark-1-first", Layer.FIRST, theme = "dark", tablet = true)

    @Test fun stepTabletDark() = shot("fr-tablet-dark-2-step", Layer.STEP, theme = "dark", tablet = true)

    @Test fun preferencesTabletDark() = shot("fr-tablet-dark-4-preferences", Layer.PREFERENCES, theme = "dark", tablet = true)

    @Test fun firstLayerGerman() = shot("de-phone-light-1-first", Layer.FIRST, lang = "de")

    @Test fun stepGerman() = shot("de-phone-light-2-step", Layer.STEP, lang = "de")

    @Test fun firstLayerArabic() = shot("ar-phone-light-1-first", Layer.FIRST, lang = "ar")

    @Test fun stepArabic() = shot("ar-phone-light-2-step", Layer.STEP, lang = "ar")

    @Test fun preferencesArabic() = shot("ar-phone-light-4-preferences", Layer.PREFERENCES, lang = "ar")

    @Test fun firstLayerLargeText() = shot("fr-phone-light-200-1-first", Layer.FIRST, scale = 2f)

    @Test fun stepLargeText() = shot("fr-phone-light-200-2-step", Layer.STEP, scale = 2f)

    @Test fun firstLayerVideoHeader() = shot("fr-phone-light-1-first-video", Layer.FIRST, video = true)

    // The IAB TCF layers (boards M7 and M15).
    @Test fun tcfFirstPhoneLight() = shot("fr-phone-light-5-tcf-first", Layer.FIRST, tcf = true)

    @Test fun tcfFirstPhoneDark() = shot("fr-phone-dark-5-tcf-first", Layer.FIRST, theme = "dark", tcf = true)

    @Test fun tcfStepPhoneLight() = shot("fr-phone-light-6-tcf-step", Layer.STEP, tcf = true)

    @Test fun tcfStepPhoneDark() = shot("fr-phone-dark-6-tcf-step", Layer.STEP, theme = "dark", tcf = true)

    @Test fun tcfPartnersPhoneLight() = shot("fr-phone-light-7-tcf-partners", Layer.PARTNERS, tcf = true)

    @Test fun tcfVendorPhoneLight() = shot("fr-phone-light-8-tcf-vendor", Layer.VENDOR, tcf = true)

    @Test fun tcfVendorPhoneDark() = shot("fr-phone-dark-8-tcf-vendor", Layer.VENDOR, theme = "dark", tcf = true)

    @Test fun tcfPreferencesPhoneLight() = shot("fr-phone-light-9-tcf-preferences", Layer.TCF_PREFERENCES, tcf = true)

    @Test fun tcfFirstTabletLight() = shot("fr-tablet-light-5-tcf-first", Layer.FIRST, tablet = true, tcf = true)

    @Test fun tcfFirstTabletDark() = shot("fr-tablet-dark-5-tcf-first", Layer.FIRST, theme = "dark", tablet = true, tcf = true)

    @Test fun tcfPartnersTabletLight() = shot("fr-tablet-light-7-tcf-partners", Layer.PARTNERS, tablet = true, tcf = true)

    @Test fun tcfFirstGerman() = shot("de-phone-light-5-tcf-first", Layer.FIRST, lang = "de", tcf = true)

    @Test fun tcfStepGerman() = shot("de-phone-light-6-tcf-step", Layer.STEP, lang = "de", tcf = true)

    @Test fun tcfFirstArabic() = shot("ar-phone-light-5-tcf-first", Layer.FIRST, lang = "ar", tcf = true)

    @Test fun tcfPartnersArabic() = shot("ar-phone-light-7-tcf-partners", Layer.PARTNERS, lang = "ar", tcf = true)

    @Test fun tcfFirstLargeText() = shot("fr-phone-light-200-5-tcf-first", Layer.FIRST, scale = 2f, tcf = true)

    @Test fun tcfStepLargeText() = shot("fr-phone-light-200-6-tcf-step", Layer.STEP, scale = 2f, tcf = true)
}
