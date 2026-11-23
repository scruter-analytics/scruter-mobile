package net.scruter.cmp.internal

import android.graphics.Bitmap
import java.io.File

/** What one display of the sheet draws, prepared on the worker (texts, words, decoded images): the UI only lays out. */
internal class SheetModel(
    val kind: Kind,
    val cmp: CmpConfig,
    val ui: UiConfig,
    /** The banner version drawn (variant B's during an A/B test). */
    val banner: Long,
    /** `a` or `b` during an A/B test, else null. */
    val variant: String?,
    val lang: String,
    val rtl: Boolean,
    val texts: Texts,
    /** The proof's `h`: the hash of the texts drawn. */
    val hash: String?,
    val words: Words,
    val policyUrl: String?,
    val poster: Bitmap?,
    val icon: Bitmap?,
    /** The icon on a disc (the store icon, `auto`) or the uploaded logo on a plate (`custom`). */
    val iconOnDisc: Boolean,
    /** The video's URL when the header is a video loop, and its file when already cached. */
    val videoUrl: String?,
    val videoFile: File?,
    /** The visitor's current answers (switches start from them; off unless granted). */
    val granted: Set<String>,
    val consentId: String?,
    val decidedAt: Long,
    /** The IAB TCF layers (§6), when the site's TCF is on and the vendor list could be read. */
    val tcf: TcfSheet? = null,
) {
    enum class Kind {
        /** The first layer, then the steps of « Personnaliser ». */
        BANNER,

        /** The app's settings entry (`showPreferences`): every purpose, the receipt. */
        PREFERENCES,
    }

    val optional: List<String> get() = cmp.purposes.filter { !it.required }.map { it.key }
    val required: List<String> get() = cmp.purposes.filter { it.required }.map { it.key }

    /** The steps of « Personnaliser »: one per optional purpose, then the partners with the TCF (board M15). */
    val stepCount: Int get() = optional.size + (if (tcf != null) 1 else 0)
}
