package net.scruter.cmp

/** The purposes every Scruter banner may have; a banner adds its own keys (`isGranted("crash_reports")`). */
public object Purpose {
    public const val NECESSARY: String = "necessary"
    public const val ANALYTICS: String = "analytics"
    public const val ADVERTISING: String = "advertising"
    public const val PERSONALIZATION: String = "personalization"
    public const val EMBEDDED_CONTENT: String = "embedded_content"
    public const val FUNCTIONAL: String = "functional"
    public const val SOCIAL_MEDIA: String = "social_media"
}

/** Where the CMP stands (docs/CMP-MOBILE.md §3.1). */
public enum class ConsentState {
    /** A valid choice for the current configuration: [ScruterCMP.isGranted] answers from it. */
    READY,

    /** The sheet must show: no choice yet, or the banner asks again (a new purpose, a revision, the period). */
    NEEDS_DECISION,

    /**
     * No configuration could be fetched and none is cached, or the app has no published banner: every optional purpose
     * stays denied; the SDK tries again at the next foreground and when the network returns.
     */
    UNAVAILABLE,
}

/** How the sheet comes up (docs/CMP-MOBILE.md §3.2). */
public enum class Presentation {
    /** Over the resumed activity, once its first frame is drawn, whenever a decision is needed. */
    AUTOMATIC,

    /** Only when the app calls [ScruterCMP.showIfNeeded] (after an onboarding; never after a paywall or a sign-in). */
    MANUAL,
}

/** A Google Consent Mode signal's value (docs/CMP-MOBILE.md §3.7). */
public enum class ConsentStatus { GRANTED, DENIED }

/** The visitor's choice. */
public class ConsentChoice internal constructor(
    /** The receipt the visitor can quote (`cns_…`): the only identifier the CMP keeps. */
    public val consentId: String,
    /** When the visitor decided, in milliseconds since the epoch. */
    public val decidedAt: Long,
    /** Every purpose of the banner: `true` granted (necessary purposes always). */
    public val purposes: Map<String, Boolean>,
) {
    public fun isGranted(purpose: String): Boolean = purposes[purpose] == true

    override fun toString(): String = "ConsentChoice($consentId, $purposes)"
}

/** Called on the main thread with the visitor's choice. */
public fun interface ConsentListener {
    public fun onConsent(choice: ConsentChoice)
}

/** Stops a listener. */
public fun interface Subscription {
    public fun cancel()
}
