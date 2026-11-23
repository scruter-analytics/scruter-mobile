package net.scruter.cmp.sample

import android.view.View
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.Espresso.pressBack
import androidx.test.espresso.accessibility.AccessibilityChecks
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.RootMatchers.isDialog
import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
import androidx.test.espresso.matcher.ViewMatchers.withId
import androidx.test.espresso.matcher.ViewMatchers.withSubstring
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import net.scruter.cmp.ConsentState
import net.scruter.cmp.Purpose
import net.scruter.cmp.ScruterCMP
import org.hamcrest.Matcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The example app on a real Android (an emulator in the CI) against the stub of the ingest (docs/CMP-MOBILE.md §9.2):
 * first launch, « Personnaliser » step by step, the settings entry and the withdrawal, Android's back, with Espresso's
 * accessibility checks on every action (touch targets, contrast, labels, traversal).
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class ConsentFlowTest {
    companion object {
        @BeforeClass
        @JvmStatic
        fun accessibility() {
            AccessibilityChecks.enable().setRunChecksFromRootView(true)
        }
    }

    @Before
    fun freshChoice() {
        // The first configuration has arrived; every test starts without a choice.
        waitUntil("the configuration") { ScruterCMP.state != ConsentState.UNAVAILABLE }
        ScruterCMP.debugReset()
        waitUntil("no choice") { ScruterCMP.state == ConsentState.NEEDS_DECISION }
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
                inSheet(withText(text)).check(matches(isDisplayed()))
                true
            } catch (e: Throwable) {
                false
            }
        }
    }

    @Test
    fun firstLaunchCustomiseThenWithdraw() {
        ActivityScenario.launch(MainActivity::class.java).use {
            sheetShows("Your data, your choices")
            // One hit per opening: the first test's opening sent it (the tests share one process and one opening).
            waitUntil("the opening's hit") { Stub.all.any { it.path == "/cmp/hit" } }
            val hit = Stub.all.first { it.path == "/cmp/hit" }.json()
            assertEquals(1, hit.getInt("d"))
            assertEquals("en", hit.getString("l"))
            assertEquals("net.scruter.cmp.sample", hit.getString("ap"))
            assertEquals(1, hit.getInt("dbg"))

            inSheet(withText("Customise")).perform(click())
            sheetShows("Step 1 of 2")
            inSheet(withContentDescription("Audience measurement")).perform(click())
            inSheet(withContentDescription("Next")).perform(click())
            sheetShows("Step 2 of 2")
            inSheet(withText("Save")).perform(click())
            val proof = Stub.proof("custom")
            assertEquals("analytics", proof.getJSONArray("g").getString(0))
            assertEquals("e".repeat(64), proof.getString("h"))
            waitUntil("the gating") { Analytics.enabled && Ads.started }
            assertTrue(ScruterCMP.isGranted(Purpose.ANALYTICS))
            assertFalse(Ads.personalized)
            onView(withId(R.id.status)).check(matches(withSubstring("Analytics: on")))

            // The settings entry: the preferences, then « Reject all » withdraws.
            onView(withId(R.id.privacy_choices)).perform(click())
            sheetShows("Your preferences")
            inSheet(withText(ScruterCMP.consentId!!)).check(matches(isDisplayed()))
            inSheet(withText("Reject all")).perform(click())
            val withdraw = Stub.proof("withdraw")
            assertEquals("preferences", withdraw.getString("o"))
            waitUntil("analytics off") { !Analytics.enabled }
            assertFalse(ScruterCMP.isGranted(Purpose.ANALYTICS))
        }
    }

    @Test
    fun androidBackIsARefusal() {
        ActivityScenario.launch(MainActivity::class.java).use {
            sheetShows("Your data, your choices")
            pressBack()
            val proof = Stub.proof("close")
            assertEquals("banner", proof.getString("o"))
            waitUntil("ready") { ScruterCMP.state == ConsentState.READY }
            assertFalse(ScruterCMP.isGranted(Purpose.ANALYTICS))
            assertFalse(ScruterCMP.isGranted(Purpose.ADVERTISING))
        }
    }

    @Test
    fun acceptAllAndTheConfirmation() {
        ActivityScenario.launch(MainActivity::class.java).use {
            sheetShows("Your data, your choices")
            inSheet(withText("Accept all")).perform(click())
            Stub.proof("accept_all")
            onView(withSubstring("Your choices have been saved.")).check(matches(isDisplayed()))
            onView(withSubstring("You can change them at any time in the app’s settings.")).check(matches(isDisplayed()))
            waitUntil("personalised ads") { Ads.personalized }
        }
    }

    @Test
    fun anotherLanguage() {
        ScruterCMP.setLanguage("de")
        try {
            ActivityScenario.launch(MainActivity::class.java).use {
                sheetShows("Ihre Daten, Ihre Wahl")
                inSheet(withText("Alle ablehnen")).perform(click())
                assertEquals("de", Stub.proof("reject_all").getString("l"))
            }
        } finally {
            ScruterCMP.setLanguage(null)
        }
    }
}

/** The Compose screen: the choice as Compose state and the same settings entry. */
@RunWith(AndroidJUnit4::class)
class ComposeScreenTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComposeActivity>()

    @Test
    fun showsTheChoice() {
        val end = System.currentTimeMillis() + 20_000
        while (ScruterCMP.state == ConsentState.UNAVAILABLE && System.currentTimeMillis() < end) Thread.sleep(100)
        compose.onNodeWithTag("compose-status").assertExists()
        if (ScruterCMP.choice != null) compose.onNodeWithTag("compose-status").assertTextContains("Analytics", substring = true)
    }
}
