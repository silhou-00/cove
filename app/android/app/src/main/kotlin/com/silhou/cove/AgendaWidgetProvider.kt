package com.silhou.cove

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import java.util.Calendar
import org.json.JSONArray

/**
 * Agenda (§6) — "What's happening today, in order?" Reads the raw
 * open-items payload `ItemRepository._refreshAgendaCache` writes and
 * decides what "today" is itself, using this device's own clock, every
 * time it renders — see the class doc on `ItemRepository._refreshAgendaCache`
 * (Flutter side) for why that's what makes the midnight rollover work
 * without a `workmanager` background job.
 *
 * Tapping a row opens that item; tapping anywhere else on the widget (the
 * root) opens the Agenda tab instead (`cove://agenda`, handled in
 * `app.dart`).
 */
class AgendaWidgetProvider : AppWidgetProvider() {
  private data class Row(val sortMinutes: Int, val timeLabel: String, val title: String, val areaColor: String, val id: String)

  override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
    for (appWidgetId in appWidgetIds) {
      updateWidget(context, appWidgetManager, appWidgetId)
    }
  }

  private fun updateWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
    val views = RemoteViews(context.packageName, R.layout.widget_agenda)
    val payload = HomeWidgetPlugin.getData(context).getString("agenda_payload", null)
    val items =
        try {
          if (payload != null) JSONArray(payload) else JSONArray()
        } catch (e: Exception) {
          JSONArray()
        }

    val today = WidgetDateUtils.todayMidnight()
    val rows = mutableListOf<Row>()

    for (i in 0 until items.length()) {
      val obj = items.getJSONObject(i)
      val title = obj.optString("title", "Untitled item")
      val areaColor = obj.optString("areaColor", "#8A8175")
      val id = obj.optString("id", "")

      val scheduled = WidgetDateUtils.parseIso(obj.optString("scheduledStart", null))
      if (scheduled != null && isToday(scheduled, today)) {
        val scheduledEnd = WidgetDateUtils.parseIso(obj.optString("scheduledEnd", null))
        val label = if (scheduledEnd != null) {
          "${WidgetDateUtils.timeString(scheduled)}\n${WidgetDateUtils.timeString(scheduledEnd)}"
        } else {
          WidgetDateUtils.timeString(scheduled)
        }
        rows.add(Row(scheduled.hour * 60 + scheduled.minute, label, title, areaColor, id))
        continue
      }
      val due = WidgetDateUtils.parseIso(obj.optString("dueAt", null))
      if (due != null && isToday(due, today)) {
        val isEndOfDay = WidgetDateUtils.isEndOfDaySentinel(due)
        val sortMinutes = if (isEndOfDay) 24 * 60 else due.hour * 60 + due.minute
        val label = if (isEndOfDay) "—" else WidgetDateUtils.timeString(due)
        rows.add(Row(sortMinutes, label, title, areaColor, id))
      }
    }
    rows.sortBy { it.sortMinutes }

    val header = "AGENDA · ${WidgetDateUtils.weekdayAbbrev(today)} ${today.get(Calendar.DAY_OF_MONTH)}"
    views.setTextViewText(R.id.header_label, header)
    views.setTextViewText(R.id.header_count, if (rows.isNotEmpty()) "${rows.size} ITEMS" else "")
    views.setViewVisibility(R.id.empty_state, if (rows.isEmpty()) View.VISIBLE else View.GONE)

    val rootIntent =
        HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("cove://agenda"))
    views.setOnClickPendingIntent(R.id.root, rootIntent)

    val rowIds = intArrayOf(R.id.row1, R.id.row2, R.id.row3, R.id.row4, R.id.row5)
    val timeIds = intArrayOf(R.id.row1_time, R.id.row2_time, R.id.row3_time, R.id.row4_time, R.id.row5_time)
    val barIds = intArrayOf(R.id.row1_bar, R.id.row2_bar, R.id.row3_bar, R.id.row4_bar, R.id.row5_bar)
    val titleIds = intArrayOf(R.id.row1_title, R.id.row2_title, R.id.row3_title, R.id.row4_title, R.id.row5_title)

    for (i in rowIds.indices) {
      if (i >= rows.size) {
        views.setViewVisibility(rowIds[i], View.GONE)
        continue
      }
      val row = rows[i]
      views.setViewVisibility(rowIds[i], View.VISIBLE)
      views.setTextViewText(timeIds[i], row.timeLabel)
      views.setTextViewText(titleIds[i], row.title)

      val barColor =
          try {
            Color.parseColor(row.areaColor)
          } catch (e: Exception) {
            Color.parseColor("#8A8175")
          }
      views.setInt(barIds[i], "setBackgroundColor", barColor)

      val pendingIntent =
          HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("cove://item/${row.id}"))
      views.setOnClickPendingIntent(rowIds[i], pendingIntent)
    }

    appWidgetManager.updateAppWidget(appWidgetId, views)
  }

  private fun isToday(date: WidgetDateUtils.ParsedDateTime, today: Calendar): Boolean {
    val cal = WidgetDateUtils.midnightOf(date)
    return cal.timeInMillis == today.timeInMillis
  }
}
