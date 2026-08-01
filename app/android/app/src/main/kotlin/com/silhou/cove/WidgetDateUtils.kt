package com.silhou.cove

import java.util.Calendar

/**
 * Shared date helpers for the three widget providers (Up Next, Agenda,
 * Areas). Dates arrive as fixed-width ISO strings
 * (`Item.*.toIso8601String()` on a local, never-UTC `DateTime`), so
 * components are sliced by position rather than parsed with `java.time` —
 * that needs API 26+ or desugaring, neither configured for this module.
 * `Calendar` is used for all "what day/week is this" math since it's safe
 * on any minSdk and its `DAY_OF_WEEK` constants (SUNDAY=1..SATURDAY=7) are
 * fixed regardless of locale, unlike `getFirstDayOfWeek()`.
 */
object WidgetDateUtils {
  data class ParsedDateTime(val year: Int, val month: Int, val day: Int, val hour: Int, val minute: Int)

  private val weekdayNames = arrayOf("SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT")

  fun parseIso(iso: String?): ParsedDateTime? {
    if (iso == null || iso.length < 16) return null
    val year = iso.substring(0, 4).toIntOrNull() ?: return null
    val month = iso.substring(5, 7).toIntOrNull() ?: return null
    val day = iso.substring(8, 10).toIntOrNull() ?: return null
    val hour = iso.substring(11, 13).toIntOrNull() ?: return null
    val minute = iso.substring(14, 16).toIntOrNull() ?: return null
    return ParsedDateTime(year, month, day, hour, minute)
  }

  /** The quick-add parser's own end-of-day sentinel for "no explicit time
   * given" (see quick_add_parser.dart) — render as a plain day label
   * instead of a misleadingly precise clock time. */
  fun isEndOfDaySentinel(p: ParsedDateTime) = p.hour == 23 && p.minute == 59

  fun midnightOf(p: ParsedDateTime): Calendar {
    val cal = Calendar.getInstance()
    cal.set(p.year, p.month - 1, p.day, 0, 0, 0)
    cal.set(Calendar.MILLISECOND, 0)
    return cal
  }

  fun todayMidnight(): Calendar {
    val cal = Calendar.getInstance()
    cal.set(Calendar.HOUR_OF_DAY, 0)
    cal.set(Calendar.MINUTE, 0)
    cal.set(Calendar.SECOND, 0)
    cal.set(Calendar.MILLISECOND, 0)
    return cal
  }

  /** Monday-starting calendar week containing today (§6). */
  fun startOfWeek(): Calendar {
    val cal = todayMidnight()
    val dow = cal.get(Calendar.DAY_OF_WEEK) // SUNDAY=1..SATURDAY=7, locale-independent
    val daysSinceMonday = (dow + 5) % 7
    cal.add(Calendar.DAY_OF_MONTH, -daysSinceMonday)
    return cal
  }

  fun weekdayAbbrev(cal: Calendar): String = weekdayNames[cal.get(Calendar.DAY_OF_WEEK) - 1]

  /** TODAY/TOMORROW/weekday-name/M-D label, matching the design's Up
   * Next/Agenda row style. [timeStr] is null/blank for the end-of-day
   * sentinel. */
  fun relativeDayLabel(p: ParsedDateTime, timeStr: String?): String {
    val due = midnightOf(p)
    val today = todayMidnight()
    val diffDays = (due.timeInMillis - today.timeInMillis) / 86_400_000L
    val hasTime = !timeStr.isNullOrEmpty()

    return when {
      diffDays == 0L -> if (hasTime) timeStr!! else "TODAY"
      diffDays == 1L -> if (hasTime) "TOMORROW $timeStr" else "TOMORROW"
      diffDays in 2..6 -> {
        val label = weekdayAbbrev(due)
        if (hasTime) "$label $timeStr" else label
      }
      else -> "${p.month}/${p.day}"
    }
  }

  fun timeString(p: ParsedDateTime): String = String.format("%02d:%02d", p.hour, p.minute)
}
