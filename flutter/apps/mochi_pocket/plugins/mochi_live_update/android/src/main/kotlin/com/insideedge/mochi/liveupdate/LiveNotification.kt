package com.insideedge.mochi.liveupdate

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle

/**
 * Mochi's one ongoing notification while Claude works: the Android twin of the iPhone's Live Activity
 * (iOS/MochiLiveActivity, iOS/Shared/MochiActivityViews.swift). The app decides what it says (`LiveUpdateView` in
 * mochi_pocket); this draws it.
 *
 * - Mochi's pose for the phase and frame, from the iPhone's own art (`mochi_scene_<phase>_<frame>`, copied from
 *   iOS/Shared/Art.xcassets at build time): Mochi alone as the large icon, the whole scene (Mochi, the desk and Patch)
 *   in the expanded view.
 * - The elapsed time as a chronometer from when the turn or wait began, while Claude works or waits.
 * - Open, and Open the Session when Claude needs you.
 * - Android 16+: asks to be promoted to a Live Update (`android.requestPromotedOngoing`), with a short status bar chip
 *   ("Needs you", "Done") when there's no timer to show. Before Android 16, or when the user turned Live Updates off
 *   for Mochi, the expanded view shows the whole scene instead.
 *
 * Updates replace it in place (one tag and id). Each carries the host's timestamp, and one older than the last posted
 * is dropped: the app and the push handler's background isolate run in this process and may both post one.
 */
object LiveNotification {
    private const val TAG = "mochi-live"
    private const val ID = 0x4D4C
    private const val QUIET_CHANNEL = "mochi_live"
    private const val ALERT_CHANNEL = "mochi_live_alert"
    private const val GROUP = "com.insideedge.mochi.live"
    private const val PREFS = "mochi_live_update"
    private const val LAST_TIMESTAMP = "timestamp"

    /** What MainActivity hands to the app when the notification or one of its buttons opened it. */
    const val EXTRA_ACTION = "com.insideedge.mochi.LIVE_ACTION"

    /** Mochi Pocket's terracotta (`Theme.tint`). */
    private const val ACCENT = 0xFFB4471C.toInt()

    private val lock = Any()

    fun show(context: Context, view: Map<String, Any?>): String = synchronized(lock) {
        val timestamp = (view["timestamp"] as? Number)?.toLong() ?: 0L
        val force = view["force"] == true
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!force && timestamp <= prefs.getLong(LAST_TIMESTAMP, Long.MIN_VALUE)) return "older"
        val manager = context.getSystemService(NotificationManager::class.java) ?: return "blocked"
        if (!force) prefs.edit().putLong(LAST_TIMESTAMP, timestamp).apply()
        if (!manager.areNotificationsEnabled()) return "blocked"
        ensureChannels(context, manager)
        manager.notify(TAG, ID, build(context, manager, view))
        "shown"
    }

    fun cancel(context: Context, timestamp: Long?, force: Boolean) = synchronized(lock) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!force && timestamp != null) {
            if (timestamp <= prefs.getLong(LAST_TIMESTAMP, Long.MIN_VALUE)) return@synchronized
            prefs.edit().putLong(LAST_TIMESTAMP, timestamp).apply()
        }
        context.getSystemService(NotificationManager::class.java)?.cancel(TAG, ID)
    }

    fun isShowing(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        return manager.activeNotifications.any { it.id == ID && it.tag == TAG }
    }

    fun status(context: Context): Map<String, Any?> {
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = manager?.getNotificationChannel(QUIET_CHANNEL)
        val enabled = manager?.areNotificationsEnabled() == true && channel?.importance != NotificationManager.IMPORTANCE_NONE
        return mapOf(
            "enabled" to enabled,
            "promotable" to if (Build.VERSION.SDK_INT >= 36) manager?.canPostPromotedNotifications() else null,
            "sdk" to Build.VERSION.SDK_INT,
        )
    }

    fun reset(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }

    // MARK: Building it

    private fun build(context: Context, manager: NotificationManager, view: Map<String, Any?>): Notification {
        val title = view["title"] as? String ?: "Mochi"
        val text = view["text"] as? String ?: ""
        val art = view["art"] as? String ?: "idle"
        val frame = (view["frame"] as? Number)?.toInt()
        val ongoing = view["ongoing"] == true
        val alert = view["alert"] == true
        val chip = view["chip"] as? String
        val since = (view["sinceMs"] as? Number)?.toLong()
        val timeout = (view["timeoutMs"] as? Number)?.toLong()
        @Suppress("UNCHECKED_CAST")
        val actions = view["actions"] as? List<String> ?: listOf("open")

        val builder = Notification.Builder(context, if (alert) ALERT_CHANNEL else QUIET_CHANNEL)
            .setSmallIcon(statusIcon(context))
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(ongoing)
            .setAutoCancel(false)
            .setOnlyAlertOnce(!alert)
            .setColor(ACCENT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(if (ongoing) Notification.CATEGORY_PROGRESS else Notification.CATEGORY_STATUS)
            .setGroup(GROUP)
            .setContentIntent(openIntent(context, "open"))
        if (since != null) {
            builder.setWhen(since).setShowWhen(true).setUsesChronometer(view["chronometer"] == true)
        }
        if (timeout != null && timeout > 0) builder.setTimeoutAfter(timeout)

        val scene = scene(context, art, frame)
        if (scene != null) builder.setLargeIcon(mochi(scene))
        for (action in actions) {
            val label = when (action) {
                "session" -> "Open the Session"
                else -> "Open"
            }
            builder.addAction(Notification.Action.Builder(null as Icon?, label, openIntent(context, action)).build())
        }

        val liveUpdate = ongoing && Build.VERSION.SDK_INT >= 36 && manager.canPostPromotedNotifications()
        if (liveUpdate) {
            // Live Updates take the standard or big-text style (not a picture), and show the chip in the status bar.
            builder.setStyle(Notification.BigTextStyle().bigText(text))
            if (Build.VERSION.SDK_INT >= 36 && chip != null) builder.setShortCriticalText(chip)
            builder.addExtras(Bundle().apply { putBoolean("android.requestPromotedOngoing", true) })
        } else if (scene != null) {
            // Expanded: the whole scene, like the iPhone's Lock Screen banner.
            builder.setStyle(
                Notification.BigPictureStyle().bigPicture(scene).bigLargeIcon(null as Icon?).setSummaryText(text),
            )
        }
        return builder.build()
    }

    private fun ensureChannels(context: Context, manager: NotificationManager) {
        if (manager.getNotificationChannel(QUIET_CHANNEL) == null) {
            // Default importance (it shows on the lock screen and in the status bar) but no sound or buzz: it changes
            // every few seconds while Claude works.
            manager.createNotificationChannel(
                NotificationChannel(QUIET_CHANNEL, "While Claude works", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "Mochi on your lock screen while Claude works on your computer, updated quietly."
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
        }
        if (manager.getNotificationChannel(ALERT_CHANNEL) == null) {
            manager.createNotificationChannel(
                NotificationChannel(ALERT_CHANNEL, "When Claude needs you", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Mochi lights up your phone when Claude is waiting for you."
                    setShowBadge(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
        }
    }

    /** The app's status bar silhouette (res/drawable/ic_stat_mochi), or the app icon. */
    private fun statusIcon(context: Context): Int {
        val id = context.resources.getIdentifier("ic_stat_mochi", "drawable", context.packageName)
        return if (id != 0) id else context.applicationInfo.icon
    }

    /** The iPhone's scene for [art] and [frame] (one of ten poses), else the phase's still, else idle's. */
    private fun scene(context: Context, art: String, frame: Int?): Bitmap? {
        val names = listOfNotNull(frame?.let { "mochi_scene_${art}_${Math.floorMod(it, 10)}" }, "mochi_scene_$art", "mochi_scene_idle")
        for (name in names) {
            val id = context.resources.getIdentifier(name, "drawable", context.packageName)
            if (id == 0) continue
            return BitmapFactory.decodeResource(context.resources, id, BitmapFactory.Options().apply { inScaled = false }) ?: continue
        }
        return null
    }

    /** Mochi alone, for the large icon: the scene's left square (Mochi stands at a quarter of its width). */
    private fun mochi(scene: Bitmap): Bitmap {
        val side = minOf(scene.width, scene.height)
        return Bitmap.createBitmap(scene, 0, 0, side, side)
    }

    private fun openIntent(context: Context, action: String): PendingIntent {
        val intent = (context.packageManager.getLaunchIntentForPackage(context.packageName) ?: Intent()).apply {
            setPackage(context.packageName)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_ACTION, action)
        }
        val requestCode = if (action == "session") 2 else 1
        return PendingIntent.getActivity(context, requestCode, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}
