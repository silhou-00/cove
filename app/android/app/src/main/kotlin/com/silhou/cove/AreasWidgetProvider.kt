package com.silhou.cove

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject

/**
 * Areas (§6) — "Where am I falling behind?" Reads the raw areas+items
 * payload `ItemRepository._refreshAreasCache` writes and reimplements §6's
 * progress formula here in Kotlin — `done_this_week / (done_this_week +
 * open_due_this_week)`, Monday-starting week, computed fresh at every
 * render using this device's own clock (same reasoning as
 * AgendaWidgetProvider — see documents/documentation.md). This is a
 * deliberate duplication of `ItemRepository.watchAreaProgress`'s Dart
 * logic: keeping the two in sync is the trade for not needing a
 * `workmanager` background job at all.
 *
 * Columns are added dynamically (`addView`, one `widget_areas_column.xml`
 * per area) rather than a fixed 4 slots, so the row scales to however
 * many areas actually exist — each column's `layout_weight="1"` shrinks
 * proportionally as more are added. Capped at [MAX_AREA_COLUMNS] purely
 * because columns eventually get too narrow to read, not because of any
 * hardcoded slot count.
 */
class AreasWidgetProvider : AppWidgetProvider() {
  companion object {
    private const val MAX_AREA_COLUMNS = 8
    private const val BAR_WIDTH_DP = 56
    private const val BAR_HEIGHT_DP = 6
    private const val TRACK_COLOR = "#E7E1D6"
    private const val FALLBACK_COLOR = "#8A8175"
  }

  private data class AreaStat(val name: String, val color: String, val doneThisWeek: Int, val openDueThisWeek: Int) {
    val hasActivity get() = doneThisWeek + openDueThisWeek > 0
    val ratio get() = if (hasActivity) doneThisWeek.toDouble() / (doneThisWeek + openDueThisWeek) else 0.0
  }

  override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
    for (appWidgetId in appWidgetIds) {
      updateWidget(context, appWidgetManager, appWidgetId)
    }
  }

  private fun updateWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
    val views = RemoteViews(context.packageName, R.layout.widget_areas)
    val payload = HomeWidgetPlugin.getData(context).getString("areas_payload", null)
    val (level, stats) = computeStats(payload)

    views.setTextViewText(R.id.header_level, "LV $level")
    views.setViewVisibility(R.id.empty_state, if (stats.isEmpty()) View.VISIBLE else View.GONE)
    val pendingIntent = HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java, Uri.parse("cove://areas"))
    views.setOnClickPendingIntent(R.id.root, pendingIntent)

    // `addView` is additive on top of whatever the widget host's own View
    // tree already has from the *previous* update — RemoteViews patches
    // the existing hierarchy in place rather than always reinflating from
    // scratch, so without this every refresh (30-min heartbeat, every
    // item mutation) kept stacking another full set of area columns onto
    // the last, squeezing all of them narrower each time.
    views.removeAllViews(R.id.columns_row)

    for (stat in stats.take(MAX_AREA_COLUMNS)) {
      val column = RemoteViews(context.packageName, R.layout.widget_areas_column)
      val color =
          try {
            Color.parseColor(stat.color)
          } catch (e: Exception) {
            Color.parseColor(FALLBACK_COLOR)
          }
      column.setImageViewBitmap(R.id.col_bar, makeBarBitmap(context, if (stat.hasActivity) stat.ratio else 0.0, color))
      val pctText = if (stat.hasActivity) "${Math.round(stat.ratio * 100)}%" else "—"
      column.setTextViewText(R.id.col_label, "${stat.name.uppercase()} $pctText")
      views.addView(R.id.columns_row, column)
    }

    appWidgetManager.updateAppWidget(appWidgetId, views)
  }

  /** A small rounded track+fill bar, drawn as a bitmap rather than a real
   * `ProgressBar` — dynamically tinting/proportioning a ProgressBar's fill
   * through RemoteViews needs `setViewLayoutWidth` (API 31+); a plain
   * bitmap works on every API level this app supports. */
  private fun makeBarBitmap(context: Context, ratio: Double, color: Int): Bitmap {
    val density = context.resources.displayMetrics.density
    val widthPx = (BAR_WIDTH_DP * density).toInt().coerceAtLeast(1)
    val heightPx = (BAR_HEIGHT_DP * density).toInt().coerceAtLeast(1)
    val bitmap = Bitmap.createBitmap(widthPx, heightPx, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val radius = heightPx / 2f

    val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = Color.parseColor(TRACK_COLOR) }
    canvas.drawRoundRect(RectF(0f, 0f, widthPx.toFloat(), heightPx.toFloat()), radius, radius, trackPaint)

    if (ratio > 0) {
      val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
      val fillWidth = (widthPx * ratio).toFloat().coerceIn(heightPx.toFloat(), widthPx.toFloat())
      canvas.drawRoundRect(RectF(0f, 0f, fillWidth, heightPx.toFloat()), radius, radius, fillPaint)
    }

    return bitmap
  }

  private fun computeStats(payload: String?): Pair<Int, List<AreaStat>> {
    if (payload == null) return Pair(1, emptyList())
    val root =
        try {
          JSONObject(payload)
        } catch (e: Exception) {
          return Pair(1, emptyList())
        }
    val level = root.optInt("level", 1)
    val areasJson = root.optJSONArray("areas") ?: return Pair(level, emptyList())
    val itemsJson = root.optJSONArray("items") ?: org.json.JSONArray()

    val weekStart = WidgetDateUtils.startOfWeek()
    val weekEnd = weekStart.clone() as java.util.Calendar
    weekEnd.add(java.util.Calendar.DAY_OF_MONTH, 7)

    val doneCounts = HashMap<String, Int>()
    val openDueCounts = HashMap<String, Int>()

    for (i in 0 until itemsJson.length()) {
      val item = itemsJson.getJSONObject(i)
      val areaId = item.optString("areaId", null) ?: continue
      val status = item.optString("status", "")

      if (status == "done") {
        val completedAt = WidgetDateUtils.parseIso(item.optString("completedAt", null))
        if (completedAt != null) {
          val cal = WidgetDateUtils.midnightOf(completedAt)
          if (cal.timeInMillis >= weekStart.timeInMillis && cal.timeInMillis < weekEnd.timeInMillis) {
            doneCounts[areaId] = (doneCounts[areaId] ?: 0) + 1
          }
        }
      } else if (status == "open") {
        val dueAt = WidgetDateUtils.parseIso(item.optString("dueAt", null))
        if (dueAt != null) {
          val cal = WidgetDateUtils.midnightOf(dueAt)
          if (cal.timeInMillis >= weekStart.timeInMillis && cal.timeInMillis < weekEnd.timeInMillis) {
            openDueCounts[areaId] = (openDueCounts[areaId] ?: 0) + 1
          }
        }
      }
    }

    val stats = mutableListOf<AreaStat>()
    for (i in 0 until areasJson.length()) {
      val area = areasJson.getJSONObject(i)
      val id = area.optString("id", "")
      stats.add(
          AreaStat(
              name = area.optString("name", ""),
              color = area.optString("color", FALLBACK_COLOR),
              doneThisWeek = doneCounts[id] ?: 0,
              openDueThisWeek = openDueCounts[id] ?: 0))
    }
    return Pair(level, stats)
  }
}
