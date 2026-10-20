package com.samsa.tmux_pocket

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONArray

const val HOST_ID = "hostId"

/** Home-screen list of saved hosts; a tap connects to that host, the header opens the host list. */
class HostsWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, views(context))
    }

    companion object {
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, HostsWidget::class.java))
            manager.notifyAppWidgetViewDataChanged(ids, R.id.hosts)
        }

        private fun launch(context: Context) = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

        @Suppress("DEPRECATION") // setRemoteAdapter(Int, Intent): the RemoteCollectionItems one needs API 31
        private fun views(context: Context) = RemoteViews(context.packageName, R.layout.hosts_widget).apply {
            setRemoteAdapter(R.id.hosts, Intent(context, HostsWidgetService::class.java))
            setEmptyView(R.id.hosts, R.id.empty)
            val list = PendingIntent.getActivity(context, 0, launch(context).putExtra(HOST_ID, ""),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            setOnClickPendingIntent(R.id.header, list)
            setOnClickPendingIntent(R.id.empty, list)
            // Mutable: each row fills in its hostId.
            setPendingIntentTemplate(R.id.hosts, PendingIntent.getActivity(context, 1, launch(context),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        }
    }
}

class HostsWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = object : RemoteViewsFactory {
        var rows = listOf<Triple<String, String, String>>() // id, name, session

        override fun onDataSetChanged() {
            rows = loadHosts(applicationContext)
        }

        override fun getViewAt(position: Int) = RemoteViews(packageName, R.layout.hosts_widget_row).apply {
            val (id, name, session) = rows[position]
            setTextViewText(R.id.name, name)
            setTextViewText(R.id.session, session)
            setOnClickFillInIntent(R.id.row, Intent().putExtra(HOST_ID, id))
        }

        override fun getCount() = rows.size
        override fun getItemId(position: Int) = position.toLong()
        override fun getLoadingView(): RemoteViews? = null
        override fun getViewTypeCount() = 1
        override fun hasStableIds() = false
        override fun onCreate() {}
        override fun onDestroy() {}
    }
}

/** Hosts as shared_preferences (legacy API) stores them: plain strings under "flutter.<key>". Secrets
 *  live in secure storage and are never read here. */
private fun loadHosts(context: Context): List<Triple<String, String, String>> {
    val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    return try {
        val hosts = JSONArray(prefs.getString("flutter.hosts", null) ?: return emptyList())
        (0 until hosts.length()).map { i ->
            val h = hosts.getJSONObject(i)
            val id = h.getString("id")
            val place = prefs.getString("flutter.place:$id", null)?.substringBefore('\t')
            Triple(id, h.optString("name"), place ?: h.optString("session", "main"))
        }
    } catch (e: Exception) {
        emptyList()
    }
}
