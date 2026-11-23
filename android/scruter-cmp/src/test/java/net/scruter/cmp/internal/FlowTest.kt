package net.scruter.cmp.internal

import android.app.Dialog
import android.widget.TextView
import net.scruter.cmp.ConsentChoice
import net.scruter.cmp.ConsentState
import net.scruter.cmp.ConsentStatus
import net.scruter.cmp.Presentation
import net.scruter.cmp.Purpose
import net.scruter.cmp.ScruterCMP
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowDialog
import java.io.File

/**
 * The CMP against a local stub of the ingest (docs/CMP-MOBILE.md §9.2): first launch, offline first launch, decision,
 * re-ask after a new configuration, withdrawal, Android's back, process death during the decision. Every beacon sent
 * is recorded for the protocol kit's schemas.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class FlowTest {
    private lateinit var server: FakeIngest

    @Before
    fun setUp() {
        Sdk.wipe()
        server = FakeIngest()
    }

    @After
    fun tearDown() {
        Sdk.stop()
        server.close()
    }

    private fun sheet(): Dialog {
        Sdk.until(what = "the sheet") { ScruterCMP.engine()?.ui?.current()?.isShowing == true }
        return ShadowDialog.getLatestDialog()
    }

    private fun root(d: Dialog) = d.window!!.decorView

    private fun launch() = Robolectric.buildActivity(TestActivity::class.java).setup()

    private fun stored(): Stored? = Stored.parse(Sdk.app.getSharedPreferences(Engine.PREFS, 0).getString(Engine.K_CHOICE, null))

    @Test
    fun firstLaunchThenAcceptAll() {
        assertEquals(ConsentState.UNAVAILABLE, ScruterCMP.state)
        Sdk.start(server)
        assertEquals(ConsentState.NEEDS_DECISION, ScruterCMP.state)
        assertFalse(ScruterCMP.isGranted(Purpose.ANALYTICS))
        var ready: ConsentChoice? = null
        var changes = 0
        ScruterCMP.whenReady { ready = it }
        ScruterCMP.onChange { changes++ }
        launch()
        val d = sheet()
        assertEquals(ConsentState.NEEDS_DECISION, ScruterCMP.state)
        assertTrue(Views.hasText(root(d), "Vos données, vos choix"))
        // TalkBack reads the whole label; on Robolectric's 320 dp phone the band only has room for « Scruter ».
        val cert = Views.all(root(d)).filterIsInstance<TextView>().single { it.contentDescription?.toString() == "Certifié par Scruter" }
        assertTrue(cert.text.endsWith("Scruter"))
        assertTrue(Views.hasText(root(d), "Politique de confidentialité"))
        // The hit leaves once the sheet shows: d = 1.
        val hit = server.next("/cmp/hit").json()
        assertEquals(1, hit.getInt("d"))
        assertEquals(412, hit.getInt("b"))
        assertEquals("android", hit.getString("p"))
        assertEquals(Sdk.app.packageName, hit.getString("ap"))
        assertTrue(hit.getString("cv").startsWith("android/"))
        Conformance.write("cmp-hit", "first-launch", hit)
        Views.click(root(d), "Tout accepter")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        assertTrue(ScruterCMP.isGranted(Purpose.ANALYTICS))
        assertTrue(ScruterCMP.isGranted(Purpose.ADVERTISING))
        assertTrue(ScruterCMP.isGranted(Purpose.NECESSARY))
        Sdk.until(what = "the listeners") { ready != null }
        assertEquals(1, changes)
        val proof = server.next("/cmp/consent").json()
        assertEquals("accept_all", proof.getString("c"))
        assertEquals("banner", proof.getString("o"))
        assertEquals(listOf("analytics", "advertising"), proof.getJSONArray("g").list())
        assertEquals(0, proof.getJSONArray("n").length())
        assertEquals(listOf("ad_storage", "ad_user_data", "ad_personalization", "analytics_storage", "security_storage"), proof.getJSONArray("m").list())
        assertEquals(ScruterCMP.consentId, proof.getString("i"))
        assertEquals("60e37e780048000a8255e6353a442ecde77e949aa68b6e19205e21945c4958a1", proof.getString("h"))
        assertEquals(3, proof.getInt("r"))
        Conformance.write("cmp-consent", "accept-all", proof)
        // Acknowledged: the pending flag goes.
        Sdk.until(what = "the acknowledgement") { stored()?.pending == null }
        assertEquals(ConsentStatus.GRANTED, ScruterCMP.consentModeSignals()["analytics_storage"])
        assertEquals(ConsentStatus.GRANTED, ScruterCMP.consentModeSignals()["security_storage"])
        assertEquals(ConsentStatus.DENIED, ScruterCMP.consentModeSignals()["functionality_storage"])
    }

    @Test
    fun customiseStepByStep() {
        Sdk.start(server)
        launch()
        val d = sheet()
        Views.click(root(d), "Personnaliser")
        Sdk.idle(100)
        assertTrue(Views.hasText(root(d), "Étape 1 sur 2"))
        assertTrue(Views.hasText(root(d), "Mesure d’audience"))
        assertTrue(Views.hasText(root(d), "Firebase Analytics"))
        // The switch starts off; turned on for analytics only.
        val sw = Views.all(root(d)).filterIsInstance<net.scruter.cmp.ui.M3Switch>().single()
        assertFalse(sw.isChecked)
        // A touch reaches it (a CompoundButton without a style is not clickable by itself).
        assertTrue(sw.isClickable && sw.isFocusable)
        sw.performClick()
        Views.click(root(d), "Suivant")
        Sdk.idle(100)
        assertTrue(Views.hasText(root(d), "Étape 2 sur 2"))
        assertTrue(Views.hasText(root(d), "Publicité"))
        Views.click(root(d), "Enregistrer")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        assertTrue(ScruterCMP.isGranted(Purpose.ANALYTICS))
        assertFalse(ScruterCMP.isGranted(Purpose.ADVERTISING))
        val proof = server.next("/cmp/consent").json()
        assertEquals("custom", proof.getString("c"))
        assertEquals(listOf("analytics"), proof.getJSONArray("g").list())
        assertEquals(listOf("advertising"), proof.getJSONArray("n").list())
        assertEquals(listOf("analytics_storage", "security_storage"), proof.getJSONArray("m").list())
        Conformance.write("cmp-consent", "custom", proof)
    }

    @Test
    fun androidBackIsCloseARefusal() {
        Sdk.start(server)
        launch()
        val d = sheet()
        @Suppress("DEPRECATION")
        d.onBackPressed()
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        assertFalse(ScruterCMP.isGranted(Purpose.ANALYTICS))
        val proof = server.next("/cmp/consent").json()
        assertEquals("close", proof.getString("c"))
        assertEquals("banner", proof.getString("o"))
        assertEquals(0, proof.getJSONArray("g").length())
        assertEquals(listOf("analytics", "advertising"), proof.getJSONArray("n").list())
        Conformance.write("cmp-consent", "android-back", proof)
    }

    @Test
    fun backInTheStepsGoesBackAStep() {
        Sdk.start(server)
        launch()
        val d = sheet()
        Views.click(root(d), "Personnaliser")
        Sdk.idle(100)
        @Suppress("DEPRECATION")
        d.onBackPressed()
        Sdk.idle(100)
        assertTrue(Views.hasText(root(d), "Vos données, vos choix"))
        assertEquals(ConsentState.NEEDS_DECISION, ScruterCMP.state)
    }

    @Test
    fun continueWithoutAccepting() {
        Sdk.start(server)
        launch()
        val d = sheet()
        Views.click(root(d), "Continuer sans accepter →")
        val proof = server.next("/cmp/consent").json()
        assertEquals("close", proof.getString("c"))
        assertFalse(ScruterCMP.isGranted(Purpose.ADVERTISING))
    }

    @Test
    fun withdrawalFromThePreferences() {
        Sdk.start(server)
        val activity = launch().get()
        val d = sheet()
        Views.click(root(d), "Tout accepter")
        server.next("/cmp/consent")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        val id = ScruterCMP.consentId
        var last: ConsentChoice? = null
        ScruterCMP.onChange { last = it }
        ScruterCMP.showPreferences(activity)
        Sdk.until(what = "the preferences") { ScruterCMP.engine()?.ui?.current()?.isShowing == true }
        val p = ShadowDialog.getLatestDialog()
        assertTrue(Views.hasText(root(p), "Vos préférences"))
        assertTrue(Views.hasText(root(p), id!!))
        assertTrue(Views.hasText(root(p), "Toujours actif"))
        Views.click(root(p), "Tout refuser")
        val proof = server.next("/cmp/consent").json()
        assertEquals("withdraw", proof.getString("c"))
        assertEquals("preferences", proof.getString("o"))
        assertEquals(id, proof.getString("i"))
        assertEquals(0, proof.getJSONArray("g").length())
        assertEquals(0L, proof.getLong("ms"))
        Conformance.write("cmp-consent", "withdraw", proof)
        Sdk.until(what = "the change") { last != null && last?.isGranted(Purpose.ANALYTICS) == false }
        assertFalse(ScruterCMP.isGranted(Purpose.ANALYTICS))
    }

    @Test
    fun preferencesCloseWithoutChange() {
        Sdk.start(server)
        val activity = launch().get()
        Views.click(root(sheet()), "Tout refuser")
        server.next("/cmp/consent")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        ScruterCMP.showPreferences(activity)
        Sdk.until(what = "the preferences") { ScruterCMP.engine()?.ui?.current()?.isShowing == true }
        @Suppress("DEPRECATION")
        ShadowDialog.getLatestDialog().onBackPressed()
        Sdk.until(what = "closed") { ScruterCMP.engine()?.ui?.current() == null }
        assertTrue(server.none("/cmp/consent"))
    }

    @Test
    fun offlineFirstLaunch() {
        server.offline = true
        Sdk.start(server)
        launch()
        Sdk.idle(1500)
        assertEquals(ConsentState.UNAVAILABLE, ScruterCMP.state)
        assertNull(ScruterCMP.engine()!!.ui.current())
        assertFalse(ScruterCMP.isGranted(Purpose.ANALYTICS))
        assertEquals(ConsentStatus.DENIED, ScruterCMP.consentModeSignals()["ad_storage"])
        // The network returns: the next attempt brings the configuration and the sheet.
        server.offline = false
        ScruterCMP.engine()!!.post { ScruterCMP.engine()!!.fetchConfig(force = true) }
        sheet()
        assertEquals(ConsentState.NEEDS_DECISION, ScruterCMP.state)
    }

    @Test
    fun noBannerGrantsNothing() {
        server.config = Protocol.file("cmp/bodies/config-off.json").readText()
        Sdk.start(server)
        launch()
        Sdk.idle(1500)
        assertEquals(ConsentState.UNAVAILABLE, ScruterCMP.state)
        assertNull(ScruterCMP.engine()!!.ui.current())
        assertTrue(server.none("/cmp/hit"))
    }

    @Test
    fun reaskAfterANewConfiguration() {
        Sdk.start(server)
        launch()
        Views.click(root(sheet()), "Tout accepter")
        server.next("/cmp/consent")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        Sdk.stop()
        // A new publication: « analytics » gained a provider (rev 4 > the choice's 3); advertising did not change.
        server.edit { o ->
            val c = o.getJSONObject("config")
            c.put("consent_rev", 4).put("config_rev", 43)
            val ps = c.getJSONArray("purposes")
            for (i in 0 until ps.length()) if (ps.getJSONObject(i).getString("key") == "analytics") ps.getJSONObject(i).put("rev", 4)
            o.put("ttl", 60)
        }
        // The next launch: the cached configuration still says « ready » until the new one arrives.
        File(Sdk.app.noBackupFilesDir, "scruter-cmp/config.meta").writeText("0\n")
        Sdk.start(server)
        launch()
        val d = sheet()
        assertEquals(ConsentState.NEEDS_DECISION, ScruterCMP.state)
        // Until the new decision, the purpose that did not change keeps its answer.
        assertFalse(ScruterCMP.isGranted(Purpose.ANALYTICS))
        assertTrue(ScruterCMP.isGranted(Purpose.ADVERTISING))
        Views.click(root(d), "Tout refuser")
        val proof = server.next("/cmp/consent").json()
        assertEquals(4, proof.getInt("r"))
        assertEquals("reject_all", proof.getString("c"))
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        assertFalse(ScruterCMP.isGranted(Purpose.ADVERTISING))
    }

    @Test
    fun processDeathDuringTheDecision() {
        // The decision is written before the sheet closes; the proof could not leave (the process died, the network
        // was gone): the next launch sends it again, with the same consent id, until the ingest acknowledges it.
        Sdk.start(server)
        launch()
        val d = sheet()
        server.offline = true
        Views.click(root(d), "Tout accepter")
        Sdk.until(what = "the choice written") { stored() != null }
        val s = stored()!!
        assertNotNull(s.pending)
        Sdk.stop()
        // The process died before the queue reached the disk.
        File(Sdk.app.noBackupFilesDir, "scruter-cmp/queue.json").delete()
        server.offline = false
        Sdk.start(server)
        assertEquals(ConsentState.READY, ScruterCMP.state)
        assertTrue(ScruterCMP.isGranted(Purpose.ANALYTICS))
        val proof = server.next("/cmp/consent").json()
        assertEquals(s.id, proof.getString("i"))
        assertEquals("accept_all", proof.getString("c"))
        assertEquals("banner", proof.getString("o"))
        Sdk.until(what = "the acknowledgement") { stored()?.pending == null }
    }

    @Test
    fun processDeathBeforeTheChoiceIsWritten() {
        Sdk.start(server)
        launch()
        sheet()
        Sdk.stop()
        assertNull(stored())
        Sdk.start(server)
        launch()
        sheet()
        assertEquals(ConsentState.NEEDS_DECISION, ScruterCMP.state)
    }

    @Test
    fun anotherLanguageIsFetched() {
        server.packs["de"] = FakeIngest.pack("de")
        Sdk.start(server)
        ScruterCMP.setLanguage("de")
        launch()
        val d = sheet()
        assertTrue(Views.hasText(root(d), "Ihre Daten, Ihre Wahl"))
        assertTrue(Views.hasText(root(d), "Ohne Zustimmung fortfahren"))
        Views.click(root(d), "Alle ablehnen")
        val proof = server.next("/cmp/consent").json()
        assertEquals("de", proof.getString("l"))
        assertEquals("d".repeat(64), proof.getString("h"))
        val hit = server.all.first { it.path == "/cmp/hit" }.json()
        assertEquals("de", hit.getString("l"))
    }

    @Test
    fun manualPresentation() {
        Sdk.start(server, Presentation.MANUAL)
        val activity = launch().get()
        Sdk.idle(1500)
        assertNull(ScruterCMP.engine()!!.ui.current())
        assertEquals(ConsentState.NEEDS_DECISION, ScruterCMP.state)
        assertTrue(ScruterCMP.showIfNeeded(activity))
        sheet()
    }

    @Test
    fun detectedSdks() {
        Sdk.start(server)
        val body = server.next("/m/v1/cmp/sdks").json()
        assertEquals("ATMONA02", body.getString("a"))
        assertEquals("android", body.getString("p"))
        assertEquals(1, body.getInt("c"))
        // org.junit.Test is on the test's class path; AppsFlyer is not.
        assertEquals(listOf("junit"), body.getJSONArray("k").list())
        Conformance.write("cmp-sdks", "detected", body)
        Sdk.stop()
        // Once per (app version, catalogue version).
        Sdk.start(server)
        assertTrue(server.none("/m/v1/cmp/sdks", 800))
    }

    @Test
    fun theQueueRetriesAndKeepsOrder() {
        server.beaconCode = 503
        Sdk.start(server)
        launch()
        Views.click(root(sheet()), "Tout refuser")
        Sdk.until(what = "the choice written") { stored() != null }
        Sdk.until(what = "a refused attempt") { server.all.any { it.path == "/cmp/consent" || it.path == "/cmp/hit" || it.path == "/m/v1/cmp/sdks" } }
        // The ingest is overloaded: nothing is acknowledged, the proof stays pending in the stored value.
        assertNotNull(stored()!!.pending)
        server.beaconCode = 202
        ScruterCMP.engine()!!.post { ScruterCMP.engine()!!.flush() }
        server.next("/cmp/hit")
        server.next("/cmp/consent")
        Sdk.until(what = "the acknowledgement") { stored()?.pending == null }
    }

    @Test
    fun debugResetForgetsTheChoice() {
        Sdk.start(server)
        launch()
        Views.click(root(sheet()), "Tout accepter")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        ScruterCMP.debugReset()
        Sdk.until(what = "asked again") { ScruterCMP.state == ConsentState.NEEDS_DECISION }
        assertNull(stored())
        assertFalse(ScruterCMP.isGranted(Purpose.ANALYTICS))
    }

    @Test
    fun startReadsTheStoredChoiceAtOnce() {
        // A previous run's choice and rules: `isGranted` answers on the next line, before any network.
        val rules = Rules(6, 412, null, listOf(Rules.Purpose("necessary", true, 1), Rules.Purpose("analytics", false, 3), Rules.Purpose("advertising", false, 1)))
        val s = Stored(Stored.newConsentId(), System.currentTimeMillis() / 1000, 3, 412, listOf("analytics"), null)
        Sdk.app.getSharedPreferences(Engine.PREFS, 0).edit().putString(Engine.K_CHOICE, s.serialize()).putString(Engine.K_RULES, rules.encode()).commit()
        server.offline = true
        ScruterCMP.start(Sdk.app, "ATMONA02", endpoint = server.url)
        assertEquals(ConsentState.READY, ScruterCMP.state)
        assertTrue(ScruterCMP.isGranted(Purpose.ANALYTICS))
        assertFalse(ScruterCMP.isGranted(Purpose.ADVERTISING))
        assertEquals(s.id, ScruterCMP.consentId)
        var got: ConsentChoice? = null
        ScruterCMP.whenReady { got = it }
        Sdk.idle()
        assertEquals(true, got?.isGranted(Purpose.ANALYTICS))
    }

    @Test
    fun anInvalidAppIdStartsNothing() {
        ScruterCMP.start(Sdk.app, "atelier mona", endpoint = server.url)
        assertNull(ScruterCMP.engine())
        assertFalse(ScruterCMP.isGranted(Purpose.ANALYTICS))
        assertEquals(ConsentState.UNAVAILABLE, ScruterCMP.state)
    }

    @Test
    fun abTestVariantIsDrawnAndSent() {
        server.edit { o ->
            val c = o.getJSONObject("config")
            val bUi = JSONObject(c.getJSONObject("ui").toString())
            bUi.getJSONObject("texts").getJSONObject("fr").put("title", "Variante B")
            c.put("ab_test", JSONObject().put("id", "0192f0c4-8a1b-7c2d-9e3f-4a5b6c7d8e9f").put("split_b", 100)
                .put("b", JSONObject().put("id", 413).put("version", 4)).put("b_ui", bUi))
        }
        Sdk.start(server)
        launch()
        val d = sheet()
        assertTrue(Views.hasText(root(d), "Variante B"))
        val hit = server.next("/cmp/hit").json()
        assertEquals("b", hit.getString("a"))
        assertEquals(413, hit.getInt("b"))
        Conformance.write("cmp-hit", "ab-variant-b", hit)
        Views.click(root(d), "Tout accepter")
        val proof = server.next("/cmp/consent").json()
        assertEquals(413, proof.getInt("b"))
        assertEquals("b", proof.getString("a"))
        assertEquals("0192f0c4-8a1b-7c2d-9e3f-4a5b6c7d8e9f", proof.getString("t"))
        Conformance.write("cmp-consent", "ab-variant-b", proof)
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
    }

    @Suppress("unused")
    private fun JSONArray.has(v: String) = list().contains(v)
}
