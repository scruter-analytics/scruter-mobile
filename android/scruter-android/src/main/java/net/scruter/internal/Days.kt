package net.scruter.internal

import java.util.Calendar
import java.util.TimeZone

/** Calendar dates in the app's time zone: the midnight of the daily id, the install day (docs/MOBILE.md §2.1). */
internal object Days {
    /** The zone named by the remote configuration, else the phone's own. */
    fun zone(id: String?): TimeZone {
        if (id != null) {
            val tz = TimeZone.getTimeZone(id)
            if (tz.id == id) return tz
        }
        return TimeZone.getDefault()
    }

    fun date(ms: Long, tz: TimeZone): String {
        val c = Calendar.getInstance(tz)
        c.timeInMillis = ms
        val y = c.get(Calendar.YEAR)
        val m = c.get(Calendar.MONTH) + 1
        val d = c.get(Calendar.DAY_OF_MONTH)
        return "$y-${if (m < 10) "0" else ""}$m-${if (d < 10) "0" else ""}$d"
    }

    /** The first instant of the day after [ms]'s in [tz]. */
    fun nextMidnight(ms: Long, tz: TimeZone): Long {
        val c = Calendar.getInstance(tz)
        c.timeInMillis = ms
        c.set(Calendar.HOUR_OF_DAY, 0)
        c.set(Calendar.MINUTE, 0)
        c.set(Calendar.SECOND, 0)
        c.set(Calendar.MILLISECOND, 0)
        c.add(Calendar.DAY_OF_MONTH, 1)
        return c.timeInMillis
    }
}
