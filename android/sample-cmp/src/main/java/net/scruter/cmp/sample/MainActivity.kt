package net.scruter.cmp.sample

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import net.scruter.cmp.ConsentChoice
import net.scruter.cmp.ScruterCMP
import net.scruter.cmp.Subscription

/** The Views screen: the app's state of consent, and its settings entry (« Privacy choices »). */
class MainActivity : Activity() {
    private lateinit var status: TextView
    private var subscription: Subscription? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (20 * resources.displayMetrics.density).toInt()
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad * 3, pad, pad)
            setBackgroundColor(Color.parseColor("#FBF8F4"))
        }
        column.addView(TextView(this).apply {
            text = getString(R.string.app_name)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
            setTextColor(Color.parseColor("#2A2521"))
        })
        status = TextView(this).apply {
            id = R.id.status
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTextColor(Color.parseColor("#2A2521"))
            setPadding(0, pad, 0, pad)
        }
        column.addView(status)
        // The settings entry (docs: « The settings entry first »): an app has no floating button, this is how a
        // visitor changes their mind or withdraws consent.
        column.addView(Button(this).apply {
            id = R.id.privacy_choices
            text = getString(R.string.privacy_choices)
            isAllCaps = false
            setOnClickListener { ScruterCMP.showPreferences(this@MainActivity) }
        })
        column.addView(Button(this).apply {
            id = R.id.open_compose
            text = getString(R.string.open_compose)
            isAllCaps = false
            setOnClickListener { startActivity(Intent(this@MainActivity, ComposeActivity::class.java)) }
        })
        column.gravity = Gravity.TOP
        setContentView(ScrollView(this).apply { addView(column) })
        render(ScruterCMP.choice)
        subscription = ScruterCMP.onChange { render(it) }
    }

    override fun onResume() {
        super.onResume()
        render(ScruterCMP.choice)
    }

    override fun onDestroy() {
        subscription?.cancel()
        super.onDestroy()
    }

    private fun render(choice: ConsentChoice?) {
        status.text = if (choice == null) {
            getString(R.string.no_choice)
        } else {
            getString(
                R.string.status,
                getString(if (Analytics.enabled) R.string.on else R.string.off),
                getString(if (!Ads.started) R.string.off else if (Ads.personalized) R.string.personalised else R.string.non_personalised),
            )
        }
        status.visibility = View.VISIBLE
    }
}
