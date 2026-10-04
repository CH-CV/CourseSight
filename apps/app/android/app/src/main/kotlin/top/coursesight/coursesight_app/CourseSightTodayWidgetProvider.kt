package top.coursesight.coursesight_app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * 4x2 今日课程小组件。数据由 Flutter 侧通过 home_widget 写入
 * SharedPreferences("HomeWidgetPreferences") 的 widget_data 字段(JSON)。
 */
class CourseSightTodayWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        val raw = prefs.getString("widget_data", null)
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.coursesight_widget_today)
            if (raw == null) {
                views.setTextViewText(R.id.widget_title, "课见")
                views.setTextViewText(R.id.widget_line_1, "长按桌面 → 添加小组件后,打开 App 导入课表")
                views.setTextViewText(R.id.widget_line_2, "")
                views.setTextViewText(R.id.widget_line_3, "")
                views.setTextViewText(R.id.widget_footer, "")
            } else {
                try {
                    val data = JSONObject(raw)
                    views.setTextViewText(
                        R.id.widget_title,
                        "今日 · " + data.optString("date", "") +
                                (if (data.isNull("week")) "" else " · 第" + data.getInt("week") + "周")
                    )
                    val today = data.optJSONArray("today")
                    val lines = listOf(R.id.widget_line_1, R.id.widget_line_2, R.id.widget_line_3)
                    for (i in lines.indices) {
                        if (today != null && i < today.length()) {
                            val c = today.getJSONObject(i)
                            val time = c.optString("time", "")
                            val name = c.optString("name", "")
                            val loc = c.optString("location", "")
                            views.setTextViewText(
                                lines[i],
                                (if (time.isEmpty()) "" else "$time ") + name +
                                        (if (loc.isEmpty()) "" else " @$loc")
                            )
                        } else {
                            val vacation = data.optBoolean("vacation", false)
                            views.setTextViewText(
                                lines[i],
                                if (i == 0)
                                    (if (vacation) "假期中,好好休息!" else "今天没有课,享受吧!")
                                else ""
                            )
                        }
                    }
                    val total = data.optInt("total", 0)
                    views.setTextViewText(
                        R.id.widget_footer,
                        if (total > 3) "还有 ${total - 3} 节课…" else ""
                    )
                } catch (e: Exception) {
                    views.setTextViewText(R.id.widget_title, "课见")
                    views.setTextViewText(R.id.widget_line_1, "数据加载失败,打开 App 刷新")
                }
            }
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
