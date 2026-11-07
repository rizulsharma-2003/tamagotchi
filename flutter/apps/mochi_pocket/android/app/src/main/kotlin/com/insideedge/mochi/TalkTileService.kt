package com.insideedge.mochi

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.insideedge.mochi.widget.WidgetView

/**
 * "Talk to Mochi" in Quick Settings (A4): a tap opens Mochi listening, as the Talk button does (tap, speak, then
 * Send), so you can ask from anywhere without finding the app. The phone unlocks first if it's locked: what you say
 * goes to your computer, which isn't for a locked phone. It isn't a toggle; it only opens Mochi (`mochi://talk`).
 */
class TalkTileService : TileService() {
    override fun onStartListening() {
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.label = getString(R.string.mochi_tile_talk)
        // Says where what you say goes, by the computer's name ("your Mac", "your PC") when Mochi knows it.
        val host = WidgetView.load(this)?.host
        tile.contentDescription = if (host == null) {
            getString(R.string.mochi_tile_talk_description)
        } else {
            getString(R.string.mochi_tile_talk_description_to, host)
        }
        tile.updateTile()
    }

    override fun onClick() {
        if (isLocked) unlockAndRun { open() } else open()
    }

    override fun onTileAdded() = remember(true)

    override fun onTileRemoved() = remember(false)

    private fun open() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("mochi://talk"), this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 3, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    /** Whether the tile is in Quick Settings, for Settings in the app (Android has no way to ask). */
    private fun remember(added: Boolean) {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(ADDED, added).apply()
    }

    companion object {
        const val PREFS = "mochi_talk_tile"
        const val ADDED = "added"

        fun isAdded(context: Context): Boolean = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(ADDED, false)
    }
}
