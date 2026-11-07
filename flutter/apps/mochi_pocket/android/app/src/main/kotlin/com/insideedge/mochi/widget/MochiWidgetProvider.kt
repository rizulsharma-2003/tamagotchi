package com.insideedge.mochi.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.format.DateFormat
import android.text.format.DateUtils
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import com.insideedge.mochi.MainActivity
import com.insideedge.mochi.R
import java.util.Date
import kotlin.math.max
import kotlin.math.min

/**
 * The home-screen widget, "Mochi & Claude" (A2): the Android twin of the iPhone's Lock Screen and Home Screen widget
 * (iOS/MochiLiveActivity/WaitingWidget.swift), with Claude as well:
 *
 * - Mochi's pose for what Claude is doing (the iPhone's scene art, `mochi_scene_<phase>[_<frame>]`), and what Claude
 *   is doing in words ("Claude needs you", "mochi-link · on your Mac").
 * - Claude's sessions on the computer, each with its status, when the computer shares summaries.
 * - "Waiting for you": how many, and the first few (meetings with their time in the phone's style).
 * - When it was last brought up to date.
 *
 * The app decides what it says ([WidgetView]); this lays it out for the widget's size and the phone's font size
 * (sections leave before rows get cut), in Mochi's clay colours, light or dark with the phone. A meeting leaves ten
 * minutes after it starts and a "Claude is working" with no word for half an hour turns idle, here, without the app:
 * Android redraws it every 30 minutes. Taps open Mochi: the top at home, the sessions at Claude's sessions, "Waiting
 * for you" at Updates.
 */
class MochiWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val view = WidgetView.load(context)
        for (id in ids) manager.updateAppWidget(id, build(context, view, manager.getAppWidgetOptions(id)))
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        manager.updateAppWidget(id, build(context, WidgetView.load(context), options))
    }

    companion object {
        /** Every size the launcher may show it at (Android 12+), else the size it has now. */
        internal fun build(context: Context, view: WidgetView?, options: Bundle?): RemoteViews {
            if (Build.VERSION.SDK_INT >= 31) {
                val sizes: List<SizeF>? = if (Build.VERSION.SDK_INT >= 33) {
                    options?.getParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, SizeF::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    options?.getParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES)
                }
                if (!sizes.isNullOrEmpty()) {
                    return RemoteViews(sizes.distinct().take(16).associateWith { render(context, view, it.width, it.height) })
                }
            }
            // Portrait: the narrowest width and the tallest height.
            val width = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)?.takeIf { it > 0 } ?: 250
            val height = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)?.takeIf { it > 0 } ?: 180
            return render(context, view, width.toFloat(), height.toFloat())
        }

        private fun render(context: Context, view: WidgetView?, width: Float, height: Float): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.mochi_widget)
            val now = System.currentTimeMillis()
            val scale = max(1f, context.resources.configuration.fontScale)
            val home = open(context, "home")
            views.setOnClickPendingIntent(android.R.id.background, home)
            views.setOnClickPendingIntent(R.id.widget_header, home)

            val wide = width >= 220f
            if (view == null || !view.paired) {
                val title = view?.title ?: context.getString(R.string.mochi_widget_label)
                val text = view?.text ?: context.getString(R.string.mochi_widget_open_mochi)
                header(context, views, title, text, "idle", null, wide)
                views.setViewVisibility(R.id.widget_sessions, View.GONE)
                views.setViewVisibility(R.id.widget_waiting, View.GONE)
                views.setViewVisibility(R.id.widget_updated, View.GONE)
                return views
            }

            val stale = view.staleAtMs?.let { now >= it } ?: false
            val items = view.items.filter { (it.leavesMs ?: Long.MAX_VALUE) > now }
            val sessions = view.sessions

            // What fits: the header always; then "Waiting for you" (a row or two), Claude's sessions, more waiting
            // rows, and the time it was updated, each only when it fits whole at this font size.
            val row = 19f * scale + 3f
            val sectionHead = 18f * scale + 18f
            val gap = 6f
            var left = height - 20f - max(50f, 47f * scale)
            fun fit(rows: Int) = min(rows, (left / row).toInt().coerceAtLeast(0))
            var waitingRows = 0
            var waitingShown = false
            if (view.waitingKnown && left >= gap + sectionHead + row) {
                waitingShown = true
                left -= gap + sectionHead
                waitingRows = fit(if (items.isEmpty()) 1 else min(items.size, 2))
                left -= waitingRows * row
            }
            var sessionRows = 0
            if (sessions.isNotEmpty() && left >= gap + sectionHead + row) {
                left -= gap + sectionHead
                sessionRows = fit(sessions.size)
                left -= sessionRows * row
            }
            if (waitingShown && items.size > waitingRows) {
                val more = fit(min(items.size, 5) - waitingRows)
                waitingRows += more
                left -= more * row
            }
            val footer = left >= 14f * scale + 4f

            val title = if (stale) view.restTitle else view.title
            var text = if (stale) view.restText else view.text
            // Too small for the list: the count joins the line under Claude.
            if (!waitingShown && view.waitingKnown && items.isNotEmpty()) {
                text = context.resources.getQuantityString(R.plurals.mochi_widget_waiting_short, items.size, items.size)
            }
            header(context, views, title, text, if (stale) view.restArt else view.art, if (stale) null else view.frame, wide)

            // Claude's sessions.
            views.removeAllViews(R.id.widget_session_rows)
            if (sessionRows > 0) {
                views.setViewVisibility(R.id.widget_sessions, View.VISIBLE)
                views.setTextViewText(R.id.widget_sessions_title, view.sessionsTitle)
                val spoken = mutableListOf<String>()
                for (session in sessions.take(sessionRows)) {
                    val line = RemoteViews(context.packageName, R.layout.mochi_widget_session)
                    line.setImageViewResource(R.id.widget_session_dot, dot(session.phase))
                    line.setTextViewText(R.id.widget_session_project, session.project)
                    line.setTextViewText(R.id.widget_session_status, session.status)
                    views.addView(R.id.widget_session_rows, line)
                    spoken += "${session.project}, ${session.status}"
                }
                views.setContentDescription(
                    R.id.widget_sessions,
                    "${view.sessionsTitle}: ${spoken.joinToString("; ")}. ${context.getString(R.string.mochi_widget_opens_sessions)}",
                )
                views.setOnClickPendingIntent(R.id.widget_sessions, open(context, "sessions"))
            } else {
                views.setViewVisibility(R.id.widget_sessions, View.GONE)
            }

            // Waiting for you.
            views.removeAllViews(R.id.widget_items)
            if (waitingShown) {
                views.setViewVisibility(R.id.widget_waiting, View.VISIBLE)
                views.setTextViewText(R.id.widget_waiting_title, view.waitingTitle)
                val spoken = mutableListOf<String>()
                if (items.isEmpty()) {
                    views.setViewVisibility(R.id.widget_waiting_count, View.GONE)
                    views.setViewVisibility(R.id.widget_waiting_empty, View.VISIBLE)
                    views.setTextViewText(R.id.widget_waiting_empty, view.emptyText)
                    spoken += view.emptyText
                } else {
                    views.setViewVisibility(R.id.widget_waiting_count, View.VISIBLE)
                    views.setTextViewText(R.id.widget_waiting_count, items.size.toString())
                    views.setViewVisibility(R.id.widget_waiting_empty, View.GONE)
                    for (item in items.take(waitingRows)) {
                        val line = RemoteViews(context.packageName, R.layout.mochi_widget_item)
                        val words = item.dueMs?.let { "${item.text} · ${DateFormat.getTimeFormat(context).format(Date(it))}" } ?: item.text
                        line.setImageViewResource(R.id.widget_item_icon, icon(item))
                        line.setTextViewText(R.id.widget_item_text, words)
                        views.addView(R.id.widget_items, line)
                        spoken += if (item.vip) context.getString(R.string.mochi_widget_vip, words) else words
                    }
                    if (items.size > waitingRows) spoken += context.getString(R.string.mochi_widget_more, items.size - waitingRows)
                }
                val count = context.resources.getQuantityString(R.plurals.mochi_widget_waiting_short, items.size, items.size)
                views.setContentDescription(
                    R.id.widget_waiting,
                    "${if (items.isEmpty()) view.waitingTitle else count}. ${spoken.joinToString("; ")}. " +
                        context.getString(R.string.mochi_widget_opens_updates),
                )
                views.setOnClickPendingIntent(R.id.widget_waiting, open(context, "updates"))
            } else {
                views.setViewVisibility(R.id.widget_waiting, View.GONE)
            }

            val updated = view.updatedMs
            if (footer && updated != null && updated > 0) {
                val time = DateUtils.formatSameDayTime(updated, now, java.text.DateFormat.SHORT, java.text.DateFormat.SHORT)
                views.setViewVisibility(R.id.widget_updated, View.VISIBLE)
                views.setTextViewText(R.id.widget_updated, context.getString(R.string.mochi_widget_updated, time))
            } else {
                views.setViewVisibility(R.id.widget_updated, View.GONE)
            }
            return views
        }

        /** Mochi's picture (the whole scene when wide, Mochi alone when narrow) and what Claude is doing. */
        private fun header(context: Context, views: RemoteViews, title: String, text: String, art: String, frame: Int?, wide: Boolean) {
            views.setTextViewText(R.id.widget_title, title)
            views.setTextViewText(R.id.widget_text, text)
            views.setViewVisibility(R.id.widget_text, if (text.isEmpty()) View.GONE else View.VISIBLE)
            views.setContentDescription(R.id.widget_header, if (text.isEmpty()) title else "$title. $text")
            val scene = sceneId(context, art, frame)
            if (wide && scene != 0) {
                views.setViewVisibility(R.id.widget_scene, View.VISIBLE)
                views.setViewVisibility(R.id.widget_mochi, View.GONE)
                views.setImageViewResource(R.id.widget_scene, scene)
            } else {
                views.setViewVisibility(R.id.widget_scene, View.GONE)
                val mochi = if (scene == 0) null else mochi(context, scene)
                if (mochi != null) {
                    views.setViewVisibility(R.id.widget_mochi, View.VISIBLE)
                    views.setImageViewBitmap(R.id.widget_mochi, mochi)
                } else {
                    views.setViewVisibility(R.id.widget_mochi, View.GONE)
                }
            }
        }

        /** The iPhone's scene for [art] and [frame] (one of ten poses), else the phase's still, else idle's. */
        private fun sceneId(context: Context, art: String, frame: Int?): Int {
            val names = listOfNotNull(frame?.let { "mochi_scene_${art}_${Math.floorMod(it, 10)}" }, "mochi_scene_$art", "mochi_scene_idle")
            for (name in names) {
                val id = context.resources.getIdentifier(name, "drawable", context.packageName)
                if (id != 0) return id
            }
            return 0
        }

        /** Mochi alone: the square around Mochi at the scene's lower left (as the lock screen's large icon). */
        private fun mochi(context: Context, scene: Int): Bitmap? {
            val bitmap = BitmapFactory.decodeResource(context.resources, scene, BitmapFactory.Options().apply { inScaled = false }) ?: return null
            val side = min((bitmap.height * 0.74f).toInt(), bitmap.width)
            val left = min((bitmap.width * 0.04f).toInt(), bitmap.width - side)
            return Bitmap.createBitmap(bitmap, left, bitmap.height - side, side, side)
        }

        private fun dot(phase: String) = when (phase) {
            "working" -> R.drawable.mochi_widget_dot_working
            "waiting" -> R.drawable.mochi_widget_dot_waiting
            "done" -> R.drawable.mochi_widget_dot_done
            "error" -> R.drawable.mochi_widget_dot_error
            else -> R.drawable.mochi_widget_dot_idle
        }

        private fun icon(item: WidgetView.Item) = when {
            item.kind == "calendar" -> R.drawable.mochi_widget_calendar
            item.kind == "notion" -> R.drawable.mochi_widget_notion
            item.vip -> R.drawable.mochi_widget_star
            item.important -> R.drawable.mochi_widget_mail_important
            else -> R.drawable.mochi_widget_mail
        }

        /** Mochi, opened at [place] (`mochi://home`, `sessions`, `updates`; MainActivity hands it to the app). */
        private fun open(context: Context, place: String): PendingIntent {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("mochi://$place"), context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            return PendingIntent.getActivity(context, place.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
    }
}
