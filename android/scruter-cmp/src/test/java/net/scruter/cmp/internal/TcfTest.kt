package net.scruter.cmp.internal

import android.app.Dialog
import android.content.SharedPreferences
import android.view.View
import net.scruter.cmp.ConsentState
import net.scruter.cmp.ScruterCMP
import net.scruter.cmp.ui.M3Switch
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

/**
 * The IAB TCF (docs/CMP-MOBILE.md §6): every vector of `sdk/protocol/cmp/tcf-vectors.json` (generated from the site
 * script's code), then the CMP with a TCF configuration: the keys in the default SharedPreferences before the sheet
 * closes and kept in step, the proof's string, the layers, the re-ask of rule 5, `debugReset()`, the TCF turned off.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class TcfTest {
    private val v = JSONObject(Protocol.file("cmp/tcf-vectors.json").readText())
    private val purposes = v.getJSONArray("purposes").let { a -> (0 until a.length()).map { a.getJSONObject(it) }.map { Rules.Purpose(it.getString("key"), it.getBoolean("required"), 1) } }
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

    private fun list(name: Any?): VendorList? = (name as? String)?.let { VendorList.parse(Protocol.file("cmp/$it").readText())!! }

    private fun ints(a: JSONArray?): List<Int> = if (a == null) emptyList() else (0 until a.length()).map { a.getInt(it) }

    private fun ids(o: JSONObject?): Map<Int, Boolean> = o?.keys()?.asSequence()?.associate { it.toInt() to o.getBoolean(it) } ?: emptyMap()

    private fun choice(o: JSONObject?): TcfChoice? = o?.let {
        TcfChoice(ids(it.optJSONObject("vendors")), ids(it.optJSONObject("vendorsLi")), ids(it.optJSONObject("purposesLi")),
            ids(it.optJSONObject("specialFeatures")), if (it.has("purposes")) ids(it.optJSONObject("purposes")) else null, ids(it.optJSONObject("ac")))
    }

    private fun check(m: TcModel, e: JSONObject, name: String) {
        assertEquals(name, e.getLong("created"), m.created)
        assertEquals(name, e.getLong("updated"), m.updated)
        assertEquals(name, listOf(e.getInt("cmpId"), e.getInt("cmpVersion"), e.getInt("consentScreen"), e.getInt("vendorListVersion"), e.getInt("policyVersion")),
            listOf(m.cmpId, m.cmpVersion, m.consentScreen, m.vendorListVersion, m.policyVersion))
        assertEquals(name, e.getString("consentLanguage").uppercase(), m.consentLanguage)
        assertEquals(name, e.getString("publisherCC"), m.publisherCC)
        assertEquals(name, ints(e.getJSONArray("specialFeatureOptins")), m.specialFeatureOptins)
        assertEquals(name, ints(e.getJSONArray("purposeConsents")), m.purposeConsents)
        assertEquals(name, ints(e.getJSONArray("purposeLegitimateInterests")), m.purposeLegitimateInterests)
        assertEquals(name, ints(e.getJSONArray("vendorConsents")), m.vendorConsents)
        assertEquals(name, ints(e.getJSONArray("vendorLegitimateInterests")), m.vendorLegitimateInterests)
        assertEquals(name, ints(e.optJSONArray("vendorsDisclosed")), m.vendorsDisclosed ?: emptyList<Int>())
        val r = e.getJSONArray("restrictions")
        assertEquals(name, (0 until r.length()).map { r.getJSONObject(it) }.map { TcRestriction(it.getInt("purpose"), it.getInt("type"), ints(it.getJSONArray("vendors")).toMutableList()) }, m.restrictions)
        val p = e.getJSONObject("publisher")
        assertEquals(name, ints(p.getJSONArray("consents")), m.publisherConsents)
        assertEquals(name, ints(p.getJSONArray("legitimateInterests")), m.publisherLegitimateInterests)
    }

    private fun keysEqual(actual: Map<String, Any>, expected: JSONObject, name: String) {
        assertEquals(name, expected.keys().asSequence().toSet(), actual.keys)
        for (k in expected.keys()) {
            val e = expected.get(k)
            if (e is Number) assertEquals("$name: $k", e.toInt(), actual[k]) else assertEquals("$name: $k", e, actual[k])
        }
    }

    @Test
    fun everyVectorEncodesAsTheWeb() {
        val cases = v.getJSONArray("cases")
        assertTrue(cases.length() > 15)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val name = c.getString("name")
            val t = TcfSettings.parse(c.getJSONObject("settings"))!!
            val g = c.getJSONObject("granted").let { o -> o.keys().asSequence().filter { o.getBoolean(it) }.toSet() }
            val m = Tcf.build(t, list(c.opt("vendor_list")), purposes, c.getString("lang"), v.getLong("now"), g, choice(c.optJSONObject("choice")))
            check(m, c.getJSONObject("model"), name)
            val tc = TcString.encode(m)
            assertEquals(name, c.getString("tc"), tc)
            // Google's Additional Consent string, for a site with its other ad tech providers.
            val ac = Tcf.ac(t, list(c.opt("vendor_list")), m, choice(c.optJSONObject("choice")))?.let { Tcf.acString(it) }
            assertEquals(name, if (c.isNull("ac")) null else c.getString("ac"), ac)
            ac?.let { assertEquals(name, it, Tcf.acString(Tcf.parseAc(it)!!)) }
            keysEqual(Tcf.keys(m, tc, ac), c.getJSONObject("keys"), name)
            val back = TcString.decode(tc)!!
            check(back, c.getJSONObject("model"), "decode: $name")
            keysEqual(Tcf.keys(back, tc, ac), c.getJSONObject("keys"), "decode: $name")
        }
    }

    @Test
    fun theReaskVectors() {
        val r = v.getJSONArray("reask")
        for (i in 0 until r.length()) {
            val c = r.getJSONObject(i)
            val t = TcfSettings.parse(c.getJSONObject("settings"))!!
            val storedAc = if (c.isNull("stored_ac")) null else c.getString("stored_ac")
            assertEquals(c.getString("name"), c.getBoolean("ask"), Tcf.mustAsk(t, c.optString("stored").ifEmpty { null }.takeIf { !c.isNull("stored") }, list(c.opt("vendor_list")), storedAc))
        }
        assertNull(TcString.decode("BOEFEAyOEFEAyAHABDENAI4AAAB9vABAASA"))
        assertNull(TcString.decode("not-a-tc-string"))
    }

    @Test
    fun additionalConsentStrings() {
        assertEquals(AcData(listOf(108, 184), listOf(2572)), Tcf.parseAc("2~108.184~dv.2572"))
        assertEquals(AcData(emptyList(), emptyList()), Tcf.parseAc("2~~dv."))
        assertEquals(AcData(listOf(1, 2), emptyList()), Tcf.parseAc("2~1.2~dv"))
        assertEquals(AcData(listOf(108, 184), emptyList()), Tcf.parseAc("1~108.184"))
        for (bad in listOf("", "2~108", "3~1~dv.2", "2~a~dv.", "2~1~dvx", "2~1~dv.2~3")) assertNull(bad, Tcf.parseAc(bad))
        assertEquals("2~108.2572~dv.", Tcf.acString(AcData(listOf(2572, 108), emptyList())))
    }

    @Test
    fun theFirstLayerSaysWhatTheWebSays() {
        val cases = v.getJSONArray("cases")
        val words = Words.load(Sdk.app, "fr")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val f = c.optJSONObject("first") ?: continue
            val l = list(c.opt("vendor_list")) ?: continue
            val name = c.getString("name")
            val sheet = TcfSheet.build(TcfSettings.parse(c.getJSONObject("settings"))!!, l, purposes, emptyMap(), words, "fr", null, 6)!!
            assertEquals(name, ints(f.getJSONArray("purposes")), (1..11).filter { it in sheet.consentPurposes || it in sheet.liPurposes })
            assertEquals(name, ints(f.getJSONArray("special_features")), sheet.specialFeatures)
            assertEquals(name, f.getInt("partners"), sheet.vendors.size + sheet.ac.size)
            f.optJSONArray("cover")?.let { cover ->
                val shown = ints(f.getJSONArray("purposes"))
                val expected = (0 until cover.length()).map { cover.getJSONObject(it) }.map { if (it.has("stack")) it.getInt("stack") else -it.getInt("purpose") }
                assertEquals(name, expected, TcfSheet.cover(l.stacks, shown.drop(1)))
                assertTrue(name, sheet.first.any { it.second })
            }
            if (!f.isNull("feature_stack")) assertEquals(name, f.getInt("feature_stack"), TcfSheet.featureStack(l.stacks, ints(f.getJSONArray("special_features"))))
        }
    }

    // ------------------------------------------------------------------------------------------------ the CMP

    private val iab: SharedPreferences get() = Sdk.app.getSharedPreferences(Sdk.app.packageName + "_preferences", 0)
    private val kept: SharedPreferences get() = Sdk.app.getSharedPreferences(Engine.PREFS, 0)

    private fun sheet(): Dialog {
        Sdk.until(what = "the sheet") { ScruterCMP.engine()?.ui?.current()?.isShowing == true }
        return ShadowDialog.getLatestDialog()
    }

    private fun root(d: Dialog): View = d.window!!.decorView

    private fun tagged(d: Dialog, tag: String): View = Views.all(root(d)).first { it.tag == tag }

    private fun launch() = Robolectric.buildActivity(TestActivity::class.java).setup()

    @Test
    fun acceptAllWritesTheKeysBeforeTheSheetClosesAndTheProofCarriesTheString() {
        server.config = server.goldenTcf()
        Sdk.start(server)
        // A CMP is there and the GDPR applies before any choice.
        assertEquals(528, iab.getInt("IABTCF_CmpSdkID", 0))
        assertEquals(1, iab.getInt("IABTCF_gdprApplies", 0))
        assertEquals("FR", iab.getString("IABTCF_PublisherCC", null))
        assertNull(iab.getString("IABTCF_TCString", null))
        launch()
        val d = sheet()
        // The TCF's ten and Google's six other partners (golden configuration).
        assertTrue(Views.hasText(root(d), "Nous et nos 16 partenaires"))
        assertTrue(Views.hasText(root(d), "Voir nos 16 partenaires"))
        // The keys are there when the app hears of the choice (the listeners run after the write, before the close).
        var seen: String? = null
        ScruterCMP.onChange { seen = iab.getString("IABTCF_TCString", null) }
        ScruterCMP.whenReady { seen = iab.getString("IABTCF_TCString", null) }
        Views.click(root(d), "Tout accepter")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        val tc = iab.getString("IABTCF_TCString", null)!!
        assertEquals(tc, seen)
        assertEquals(tc, kept.getString("tcf", null))
        assertEquals("10110000100", iab.getString("IABTCF_PurposeConsents", null))
        assertEquals("11", iab.getString("IABTCF_SpecialFeaturesOptIns", null))
        val expected = v.getJSONArray("cases").getJSONObject(0)
        assertEquals(ints(expected.getJSONObject("model").getJSONArray("vendorConsents")), TcString.decode(tc)!!.vendorConsents)
        // Google's Additional Consent string beside it, kept and sent with the proof after `~`.
        val ac = "2~108.184.486.1301.2572.3234~dv."
        assertEquals(ac, iab.getString("IABTCF_AddtlConsent", null))
        assertEquals(ac, kept.getString("tcfAc", null))
        val proof = server.next("/cmp/consent").json()
        assertEquals("$tc~$ac", proof.getString("tc"))
        assertEquals(186, proof.getInt("gv"))
        Conformance.write("cmp-consent", "tcf-accept-all", proof)
    }

    @Test
    fun rejectAllThenTheLayersChoiceAndTheStoredChoiceInThePreferences() {
        server.config = server.goldenTcf()
        Sdk.start(server)
        val activity = launch().get()
        var d = sheet()
        Views.click(root(d), "Tout refuser")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        assertEquals("00000000000", iab.getString("IABTCF_PurposeConsents", null))
        assertEquals("", iab.getString("IABTCF_VendorConsents", null))
        assertEquals("", iab.getString("IABTCF_VendorLegitimateInterests", null))
        assertEquals("2~~dv.108.184.486.1301.2572.3234", iab.getString("IABTCF_AddtlConsent", null))
        Sdk.until(what = "closed") { ScruterCMP.engine()?.ui?.current() == null }
        // The preferences: the partners, one partner's objection, « Enregistrer ».
        ScruterCMP.showPreferences(activity)
        d = sheet()
        tagged(d, "scruter-cmp-tcf-partners").performClick()
        Sdk.idle(200)
        d = ShadowDialog.getLatestDialog()
        assertTrue(Views.hasText(root(d), "Partenaires inscrits au TCF de l’IAB Europe (10)"))
        // Google's other ad tech providers in their own group after the TCF's partners.
        assertTrue(Views.hasText(root(d), "Autres partenaires de Google (6)".uppercase(java.util.Locale.FRENCH)))
        assertFalse("refused with « Tout refuser »", (tagged(d, "scruter-cmp-ac-consent-108") as M3Switch).isChecked)
        tagged(d, "scruter-cmp-vendor-21").performClick()
        Sdk.idle(200)
        d = ShadowDialog.getLatestDialog()
        assertTrue(Views.hasText(root(d), "The UK Trade Desk Ltd"))
        val li = tagged(d, "scruter-cmp-detail-li") as M3Switch
        assertFalse("the stored choice: no legitimate interest after « Tout refuser »", li.isChecked)
        li.performClick()
        assertTrue(li.isChecked)
        Views.click(root(d), "Enregistrer")
        Sdk.until(what = "the new string") { iab.getString("IABTCF_VendorLegitimateInterests", null)?.length ?: 0 > 20 }
        val vli = iab.getString("IABTCF_VendorLegitimateInterests", null)!!
        assertEquals('1', vli[20])
    }

    @Test
    fun aStepShowsTheIabPurposesThatFollowTheBannerPurpose() {
        server.config = server.goldenTcf()
        Sdk.start(server)
        launch()
        var d = sheet()
        Views.click(root(d), "Personnaliser")
        Sdk.idle(200)
        d = ShadowDialog.getLatestDialog()
        // Step 1: analytics, with IAB purposes 9 and 10 grouped under it.
        assertTrue(Views.hasText(root(d), "Étape 1 sur 3"))
        val p9 = tagged(d, "scruter-cmp-iab-9") as M3Switch
        assertFalse(p9.isChecked)
        val analytics = Views.all(root(d)).filterIsInstance<M3Switch>().first { it.contentDescription == "Mesure d’audience" }
        analytics.performClick()
        assertTrue("an untouched IAB purpose follows its banner purpose", p9.isChecked)
        p9.performClick()
        assertFalse(p9.isChecked)
        Views.click(root(d), "Suivant")
        Sdk.idle(200)
        Views.click(root(ShadowDialog.getLatestDialog()), "Suivant")
        Sdk.idle(200)
        d = ShadowDialog.getLatestDialog()
        assertTrue(Views.hasText(root(d), "Étape 3 sur 3"))
        assertTrue(Views.hasText(root(d), "Partenaires inscrits au TCF de l’IAB Europe (10)"))
        Views.click(root(d), "Enregistrer")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        assertEquals("purpose 9 refused by hand, 1–4 follow advertising (refused)", "00000000000", iab.getString("IABTCF_PurposeConsents", null))
        assertEquals("custom", server.next("/cmp/consent").json().getString("c"))
    }

    @Test
    fun aNewPolicyAsksAgainDebugResetAndTheTcfTurnedOff() {
        server.config = server.goldenTcf()
        Sdk.start(server)
        launch()
        Views.click(root(sheet()), "Tout accepter")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        val tc = iab.getString("IABTCF_TCString", null)!!
        Sdk.stop()
        // An app removed the keys: the next launch writes them again from the stored string.
        iab.edit().clear().commit()
        Sdk.start(server)
        Sdk.until(what = "the keys again") { iab.getString("IABTCF_TCString", null) == tc }
        assertEquals(ConsentState.READY, ScruterCMP.state)
        Sdk.stop()
        // A new TCF policy: asked again, the previous answers hold until the new decision.
        server.edit { o ->
            val c = o.getJSONObject("config")
            c.getJSONObject("tcf").put("policy_version", 6)
            c.put("config_rev", 43)
        }
        // The next launch fetches it (the cached one is no longer fresh).
        java.io.File(Sdk.app.noBackupFilesDir, "scruter-cmp/config.meta").writeText("0\n")
        Sdk.start(server)
        Sdk.until(what = "asked again") { ScruterCMP.state == ConsentState.NEEDS_DECISION }
        assertEquals(6, iab.getInt("IABTCF_PolicyVersion", 0))
        assertEquals(tc, iab.getString("IABTCF_TCString", null))
        // debugReset(): the choice and its string go; the header stays for the configuration.
        ScruterCMP.debugReset()
        Sdk.until(what = "reset") { kept.getString("tcf", null) == null }
        assertNull(iab.getString("IABTCF_TCString", null))
        assertNull(iab.getString("IABTCF_AddtlConsent", null))
        assertEquals(1, iab.getInt("IABTCF_gdprApplies", 0))
        Sdk.stop()
        // The site turns the TCF off: nothing of ours stays for vendors.
        server.config = server.golden()
        server.etag = "\"a-off0000000000000000\""
        java.io.File(Sdk.app.noBackupFilesDir, "scruter-cmp/config.meta").writeText("0\n")
        Sdk.start(server)
        Sdk.until(what = "the keys removed") { iab.all.keys.none { it.startsWith("IABTCF_") } }
        assertFalse(kept.contains("tcfKeys"))
    }

    @Test
    fun withoutTheVendorListTheStandardLayersShow() {
        server.edit { o -> o.getJSONObject("config").put("tcf", JSONObject(server.goldenTcf()).getJSONObject("config").getJSONObject("tcf").put("vendors_url", "/cmp/ATMONA02/missing.json")) }
        Sdk.start(server)
        launch()
        val d = sheet()
        assertTrue(Views.hasText(root(d), "Vos données, vos choix"))
        assertFalse(Views.hasText(root(d), "Voir nos"))
        Views.click(root(d), "Tout accepter")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        val m = TcString.decode(iab.getString("IABTCF_TCString", null)!!)!!
        assertEquals(emptyList<Int>(), m.vendorsDisclosed)
        assertEquals("nothing disclosed, nothing consented", "2~~dv.", iab.getString("IABTCF_AddtlConsent", null))
        assertNotNull(server.next("/cmp/consent").json().optString("tc").ifEmpty { null })
    }

    @Test
    fun aProviderOfGoogleTheStoredStringDidNotNameAsksAgain() {
        val golden = server.goldenTcf()
        server.edit { o -> o.getJSONObject("config").put("tcf", JSONObject(golden).getJSONObject("config").getJSONObject("tcf").put("ac_providers", JSONArray(listOf(108, 184, 486, 1301, 2572)))) }
        Sdk.start(server)
        launch()
        Views.click(root(sheet()), "Tout accepter")
        Sdk.until(what = "ready") { ScruterCMP.state == ConsentState.READY }
        assertEquals("2~108.184.486.1301.2572~dv.", iab.getString("IABTCF_AddtlConsent", null))
        Sdk.stop()
        // 3234 added, on Google's list: asked again.
        server.config = golden
        server.edit { o -> o.getJSONObject("config").put("config_rev", 43) }
        java.io.File(Sdk.app.noBackupFilesDir, "scruter-cmp/config.meta").writeText("0\n")
        Sdk.start(server)
        Sdk.until(what = "asked again") { ScruterCMP.state == ConsentState.NEEDS_DECISION }
    }
}
