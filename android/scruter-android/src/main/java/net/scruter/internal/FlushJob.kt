package net.scruter.internal

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Build
import net.scruter.Scruter

/**
 * The flush when the app goes to the background (docs/MOBILE.md §3.15): an expedited platform job with a network
 * constraint (what WorkManager's expedited work is built on, without the dependency), so that the session's last state
 * leaves the phone even when the process is about to be frozen or the network is back only later. One shot: no timer.
 */
public class FlushJob : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        val engine = Scruter.engine() ?: return false
        engine.post {
            engine.flush("background job")
            jobFinished(params, false)
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean = false

    internal companion object {
        const val JOB_ID = 0x5C2_0717

        fun schedule(context: Context) {
            try {
                val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler ?: return
                val b = JobInfo.Builder(JOB_ID, ComponentName(context, FlushJob::class.java))
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                if (Build.VERSION.SDK_INT >= 31) b.setExpedited(true) else b.setOverrideDeadline(60_000)
                scheduler.schedule(b.build())
            } catch (e: Exception) {
                // Quota or a missing declaration: the queue waits for the next launch.
                Log.d("background flush not scheduled: ${e.javaClass.simpleName}")
            }
        }
    }
}
