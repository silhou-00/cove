package com.silhou.cove

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray

/**
 * Up Next (§6) — "What's closing in on me?" Reads the JSON payload
 * ItemRepository writes via `HomeWidget.saveWidgetData` (Flutter side:
 * lib/data/repositories/item_repository.dart) and renders up to 3 rows,
 * since that's what a 4×2 grid realistically fits. Refresh is two of the
 * three required paths from §6: on-mutation (`_notifyWidgets` calling
 * `HomeWidget.updateWidget()`) and the 30-minute heartbeat floor declared
 * in up_next_widget_info.xml. The midnight-rollover mechanism the spec
 * names (a `workmanager` job) isn't built — see documents/documentation.md
 * for why the heartbeat plus native-side date math covers the same need.
 *
 * Each row's circle (`rowN_check`) completes that item/occurrence via
 * `HomeWidgetBackgroundIntent` — a broadcast that runs
 * `lib/app/widget_background.dart`'s callback in a background Dart
 * isolate, no app launch, same as tapping the in-app complete circle.
 * Tapping anywhere else on the widget (the root) opens the Up Next tab
 * instead (`cove://upnext`, handled in `app.dart`).
 */
class UpNextWidgetProvider : AppWidgetProvider() {
  override fun onUpdate(
      context: Context,
      appWidgetManager: AppWidgetManager,
      appWidgetIds: IntArray
  ) {
    for (appWidgetId in appWidgetIds) {
      updateWidget(context, appWidgetManager, appWidgetId)
    }
  }

  private fun updateWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
    val views = RemoteViews(context.packageName, R.layout.widget_up_next)
    val payload = HomeWidgetPlugin.getData(context).getString("up_next_payload", null)
    val items =
        try {
          if (payload != null) JSONArray(payload) else JSONArray()
        } catch (e: Exception) {
          JSONArray()
        }

    views.setTextViewText(
        R.id.header_count,
        if (items.length() > 0) "${items.length()} OPEN" else "")
    views.setViewVisibility(R.id.empty_state, if (items.length() == 0) View.VISIBLE else View.GONE)

    val rootIntent =
        HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("cove://upnext"))
    views.setOnClickPendingIntent(R.id.root, rootIntent)

    val rowIds = intArrayOf(R.id.row1, R.id.row2, R.id.row3)
    val barIds = intArrayOf(R.id.row1_bar, R.id.row2_bar, R.id.row3_bar)
    val titleIds = intArrayOf(R.id.row1_title, R.id.row2_title, R.id.row3_title)
    val metaIds = intArrayOf(R.id.row1_meta, R.id.row2_meta, R.id.row3_meta)
    val checkIds = intArrayOf(R.id.row1_check, R.id.row2_check, R.id.row3_check)

    for (i in rowIds.indices) {
      if (i >= items.length()) {
        views.setViewVisibility(rowIds[i], View.GONE)
        continue
      }
      views.setViewVisibility(rowIds[i], View.VISIBLE)
      val obj = items.getJSONObject(i)
      val title = obj.optString("title", "Untitled item")
      val area = obj.optString("area", "")
      val dueLabel = formatDueLabel(obj.optString("dueAt", null))

      views.setTextViewText(titleIds[i], title)
      views.setTextViewText(metaIds[i], if (area.isNotEmpty()) "$dueLabel · ${area.uppercase()}" else dueLabel)

      val barColor =
          try {
            Color.parseColor(obj.optString("areaColor", "#8A8175"))
          } catch (e: Exception) {
            Color.parseColor("#8A8175")
          }
      views.setInt(barIds[i], "setBackgroundColor", barColor)

      val itemId = obj.optString("id", "")
      val pendingIntent =
          HomeWidgetLaunchIntent.getActivity(
              context, MainActivity::class.java, Uri.parse("cove://item/$itemId"))
      views.setOnClickPendingIntent(rowIds[i], pendingIntent)

      val occurrenceId = obj.optString("occurrenceId", "")
      val completeUri =
          Uri.parse("cove://complete").buildUpon().appendQueryParameter("itemId", itemId).let {
            if (occurrenceId.isNotEmpty()) it.appendQueryParameter("occurrenceId", occurrenceId) else it
          }.build()
      views.setOnClickPendingIntent(
          checkIds[i], HomeWidgetBackgroundIntent.getBroadcast(context, completeUri))
    }

    appWidgetManager.updateAppWidget(appWidgetId, views)
  }

  private fun formatDueLabel(iso: String?): String {
    val parsed = WidgetDateUtils.parseIso(iso) ?: return ""
    val timeStr = if (WidgetDateUtils.isEndOfDaySentinel(parsed)) null else WidgetDateUtils.timeString(parsed)
    return WidgetDateUtils.relativeDayLabel(parsed, timeStr)
  }
}
