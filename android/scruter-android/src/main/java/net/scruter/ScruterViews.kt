@file:JvmName("ScruterViews")

package net.scruter

import android.view.View

/**
 * Android Views helpers (docs/MOBILE.md §3.5, §3.9, §3.11). From a layout, the same with a keyed tag:
 *
 * ```xml
 * <TextView …>
 *     <tag android:id="@id/scruter_mask" android:value="true" />
 * </TextView>
 * ```
 */

/** Masks this view in the team phones' screen images (text inputs and web views are always masked). */
public var View.scruterMask: Boolean
    get() = getTag(R.id.scruter_mask).let { it == true || it == "true" }
    set(value) = setTag(R.id.scruter_mask, if (value) true else null)

/** Taps inside this view are not collected and it is left out of the screen images' element tree. */
public var View.scruterIgnore: Boolean
    get() = getTag(R.id.scruter_ignore).let { it == true || it == "true" }
    set(value) = setTag(R.id.scruter_ignore, if (value) true else null)

/** A stable identifier for this view (written `#addToCart` in Screen analysis), else its id's resource name. */
public var View.scruterId: String?
    get() = getTag(R.id.scruter_id) as? String
    set(value) = setTag(R.id.scruter_id, value)

/** The fields inside this view form "[scruterForm]" in Forms. */
public var View.scruterForm: String?
    get() = getTag(R.id.scruter_form) as? String
    set(value) = setTag(R.id.scruter_form, value)
