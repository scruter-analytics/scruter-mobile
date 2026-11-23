package net.scruter.sample

import android.content.Intent
import android.os.Bundle
import android.system.Os
import android.system.OsConstants
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.textfield.TextInputLayout
import net.scruter.Scruter

/** Hosts a fragment: the screen counted is "Catalog", not "Home". */
class HomeActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_home)
        if (BuildConfig.SELF_CHECK) SelfCheck.crashIfAsked(intent, window.decorView)
        findViewById<Button>(R.id.open_checkout).setOnClickListener {
            startActivity(Intent(this, CheckoutActivity::class.java))
        }
        findViewById<Button>(R.id.open_compose).setOnClickListener {
            startActivity(Intent(this, ComposeShopActivity::class.java))
        }
    }
}

/** 2 000 elements: scripts/device-check.mjs reads what a tap's identity costs on such a screen (docs/MOBILE.md §3.18). */
class StressActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        repeat(400) {
            val row = LinearLayout(this)
            repeat(4) { row.addView(TextView(this).apply { text = "x" }) }
            root.addView(row)
        }
        setContentView(ScrollView(this).apply { addView(root) })
    }
}

/** scripts/device-check.mjs asks for real crashes of the release build (never compiled in by default). */
internal object SelfCheck {
    fun crashIfAsked(intent: Intent, view: View) {
        when (intent.getStringExtra("scruter_crash")) {
            "java" -> view.postDelayed({ throw IllegalStateException("Self-check crash") }, 1500)
            "native" -> view.postDelayed({ Os.kill(Os.getpid(), OsConstants.SIGSEGV) }, 1500)
        }
    }
}

class CatalogFragment : Fragment() {
    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View =
        inflater.inflate(R.layout.fragment_catalog, container, false)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        val list = view as RecyclerView
        list.layoutManager = LinearLayoutManager(requireContext())
        list.adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(
                LayoutInflater.from(parent.context).inflate(R.layout.item_product, parent, false),
            ) {}

            override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
                val item = holder.itemView as TextView
                item.text = getString(R.string.product, position)
                item.setOnClickListener { Scruter.track("Product viewed", mapOf("position" to position)) }
            }

            override fun getItemCount() = 200
        }
    }
}

class CheckoutActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_checkout)
        findViewById<Button>(R.id.pay).setOnClickListener {
            val postal = findViewById<TextView>(R.id.postal_code)
            val layout = findViewById<TextInputLayout>(R.id.postal_layout)
            if (postal.text.isNullOrEmpty()) {
                layout.error = getString(R.string.postal_code)
            } else {
                layout.error = null
                Scruter.track("Order placed", revenue = 49.0, currency = "EUR")
                Scruter.formSent("Delivery")
                finish()
            }
        }
    }
}
