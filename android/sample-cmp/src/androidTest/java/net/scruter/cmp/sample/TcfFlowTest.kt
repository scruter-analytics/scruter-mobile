package net.scruter.cmp.sample

import android.content.Context
import android.content.SharedPreferences
import android.view.View
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.accessibility.AccessibilityChecks
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.openLinkWithText
import androidx.test.espresso.action.ViewActions.scrollTo
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.RootMatchers.isDialog
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withSubstring
import androidx.test.espresso.matcher.ViewMatchers.withTagValue
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import net.scruter.cmp.ConsentState
import net.scruter.cmp.ScruterCMP
import org.hamcrest.Matcher
import org.hamcrest.CoreMatchers.`is`
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The IAB TCF in the example app (docs/CMP-MOBILE.md §6), in its own run (`-e tcf true`: the stub serves
 * `config-tcf.json` and the kit's GVL 186 vendors from the first launch): the first layer with IAB's text, accept all,
 * reject all, an objection to a partner's legitimate interest, the keys in the default SharedPreferences before the app
 * hears of the choice, `debugReset()`, with Espresso's accessibility checks on every action.
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class TcfFlowTest {
    companion object {
        @BeforeClass
        @JvmStatic
        fun accessibility() {
            AccessibilityChecks.enable().setRunChecksFromRootView(true)
        }
    }

    private val app: Context get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
    private val iab: SharedPreferences get() = app.getSharedPreferences(app.packageName + "_preferences", Context.MODE_PRIVATE)

    @Before
    fun freshChoice() {
        assumeTrue("run with -e tcf true", Stub.tcf)
        waitUntil("the configuration") { ScruterCMP.state != ConsentState.UNAVAILABLE }
        ScruterCMP.debugReset()
        waitUntil("no choice") { ScruterCMP.state == ConsentState.NEEDS_DECISION && iab.getString("IABTCF_TCString", null) == null }
        Stub.requests.clear()
    }

    private fun waitUntil(what: String, seconds: Long = 20, cond: () -> Boolean) {
        val end = System.currentTimeMillis() + seconds * 1000
        while (System.currentTimeMillis() < end) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            if (cond()) return
            Thread.sleep(100)
        }
        throw AssertionError("timed out waiting for $what")
    }

    private fun inSheet(m: Matcher<View>) = onView(m).inRoot(isDialog())

    private fun sheetShows(text: String) {
        waitUntil("the sheet") {
            try {
                inSheet(withSubstring(text)).check(matches(isDisplayed()))
                true
            } catch (e: Throwable) {
                false
            }
        }
    }

    @Test
    fun acceptAllWritesTheKeysBeforeTheAppHearsOfIt() {
        // A CMP is there and the GDPR applies before any choice.
        assertEquals(528, iab.getInt("IABTCF_CmpSdkID", 0))
        assertEquals(1, iab.getInt("IABTCF_gdprApplies", 0))
        var seen: String? = "unset"
        val sub = ScruterCMP.onChange { seen = iab.getString("IABTCF_TCString", null) }
        ActivityScenario.launch(MainActivity::class.java).use {
            sheetShows("We and our 16 partners")
            inSheet(withText("Accept all")).perform(click())
            val proof = Stub.proof("accept_all")
            // The TC string, then Google's Additional Consent string after `~` (the golden configuration's providers).
            val tc = proof.getString("tc").substringBefore('~')
            val ac = proof.getString("tc").substringAfter('~', "")
            assertEquals(186, proof.getInt("gv"))
            waitUntil("the listener") { seen != "unset" }
            assertEquals("the keys are written before the app hears of the choice", tc, seen)
            assertEquals("2~108.184.486.1301.2572.3234~dv.", ac)
            assertEquals(ac, iab.getString("IABTCF_AddtlConsent", null))
            assertEquals("10110000100", iab.getString("IABTCF_PurposeConsents", null))
            assertEquals("11", iab.getString("IABTCF_SpecialFeaturesOptIns", null))
        }
        sub.cancel()
    }

    @Test
    fun rejectAll() {
        ActivityScenario.launch(MainActivity::class.java).use {
            sheetShows("We and our 16 partners")
            inSheet(withText("Reject all")).perform(click())
            assertNotNull(Stub.proof("reject_all").optString("tc").ifEmpty { null })
            waitUntil("the keys") { iab.getString("IABTCF_TCString", null) != null }
            assertEquals("00000000000", iab.getString("IABTCF_PurposeConsents", null))
            assertEquals("", iab.getString("IABTCF_VendorConsents", null))
            assertEquals("", iab.getString("IABTCF_VendorLegitimateInterests", null))
        }
    }

    @Test
    fun anObjectionToAPartnersLegitimateInterestThenDebugReset() {
        ActivityScenario.launch(MainActivity::class.java).use {
            sheetShows("We and our 16 partners")
            // « See our 16 partners », a link of the first layer's small print: the partners' step.
            inSheet(withTagValue(`is`("scruter-cmp-tcf-note"))).perform(openLinkWithText("See our 16 partners"))
            sheetShows("Partners registered with the IAB Europe TCF (10)")
            inSheet(withTagValue(`is`("scruter-cmp-vendor-21"))).perform(scrollTo(), click())
            sheetShows("The UK Trade Desk Ltd")
            inSheet(withTagValue(`is`("scruter-cmp-detail-li"))).perform(scrollTo(), click())
            inSheet(withText("Save")).perform(click())
            assertEquals("custom", Stub.proof("custom").getString("c"))
            waitUntil("the keys") { (iab.getString("IABTCF_VendorLegitimateInterests", null)?.length ?: 0) > 31 }
            val vli = iab.getString("IABTCF_VendorLegitimateInterests", null)!!
            assertEquals("vendor 21 objected to: $vli", '0', vli[20])
            assertEquals("Xandr (32) keeps its legitimate interest: $vli", '1', vli[31])
        }
        // debugReset(): the choice and its keys go; the header stays for the configuration.
        ScruterCMP.debugReset()
        waitUntil("reset") { iab.getString("IABTCF_TCString", null) == null }
        assertNull(iab.getString("IABTCF_VendorConsents", null))
        assertEquals(1, iab.getInt("IABTCF_gdprApplies", 0))
    }
}
