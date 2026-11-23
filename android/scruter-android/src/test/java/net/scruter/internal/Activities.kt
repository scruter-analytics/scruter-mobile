package net.scruter.internal

import android.app.Activity
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import net.scruter.ScruterScreen
import net.scruter.scruterForm
import net.scruter.scruterId
import net.scruter.scruterMask

/** A product screen built from code: a button, texts, a form, a masked view, in a tall scroll view. */
class ProductActivity : Activity() {
    lateinit var button: Button
    lateinit var description: TextView
    lateinit var postal: EditText
    lateinit var password: EditText
    lateinit var terms: CheckBox
    lateinit var secret: TextView
    lateinit var scroll: ScrollView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val column = LinearLayout(this)
        column.orientation = LinearLayout.VERTICAL
        button = Button(this).apply {
            id = android.R.id.button1
            text = "Add to cart"
            setOnClickListener { }
        }
        description = TextView(this).apply {
            id = android.R.id.text1
            text = "A stoneware vase"
        }
        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            scruterForm = "Delivery"
        }
        postal = EditText(this).apply {
            scruterId = "postalCode"
            inputType = InputType.TYPE_CLASS_NUMBER
        }
        password = EditText(this).apply { inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD }
        terms = CheckBox(this).apply { scruterId = "terms" }
        form.addView(postal)
        form.addView(password)
        form.addView(terms)
        secret = TextView(this).apply {
            text = "Morgan Smith"
            scruterMask = true
        }
        column.addView(button)
        column.addView(description)
        column.addView(form)
        column.addView(secret)
        column.addView(android.webkit.WebView(this), ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 200))
        column.addView(View(this), ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 4000))
        scroll = ScrollView(this)
        scroll.addView(column)
        setContentView(scroll)
    }
}

@ScruterScreen("Shopping cart")
class CartActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply { text = "Shopping cart" })
    }
}

class ListActivity : Activity() {
    lateinit var list: RecyclerView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        list = RecyclerView(this)
        list.id = android.R.id.list
        list.layoutManager = LinearLayoutManager(this)
        list.adapter = object : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
            override fun onCreateViewHolder(parent: ViewGroup, viewType: Int) = object : RecyclerView.ViewHolder(
                LinearLayout(parent.context).apply {
                    layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 120)
                    isClickable = true
                    addView(TextView(parent.context))
                },
            ) {}

            override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
                ((holder.itemView as LinearLayout).getChildAt(0) as TextView).text = "Product $position"
            }

            override fun getItemCount() = 100
        }
        setContentView(list)
    }
}
