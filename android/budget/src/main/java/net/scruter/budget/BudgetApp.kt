package net.scruter.budget

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.widget.TextView

class BudgetApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Measure.start(this)
    }
}

class BudgetActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = TextView(this)
        text.text = intent?.action.orEmpty()
        text.setOnClickListener { Measure.use(it) }
        setContentView(text)
    }
}
