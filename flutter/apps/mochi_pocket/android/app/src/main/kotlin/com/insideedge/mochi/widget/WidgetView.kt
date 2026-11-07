package com.insideedge.mochi.widget

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * What the app last gave the widget: `HomeWidgetView.of` in lib/src/widget/home_widget.dart, kept by
 * plugins/mochi_home_widget in the preferences below. The words are the app's (they name the real computer); the
 * widget only lays them out, formats times the phone's way and drops what has passed.
 */
internal class WidgetView(private val json: JSONObject) {
    class Session(val project: String, val status: String, val phase: String)

    class Item(val kind: String, val text: String, val vip: Boolean, val important: Boolean, val dueMs: Long?, val leavesMs: Long?)

    val paired get() = json.optBoolean("paired", false)
    val petName get() = string("petName") ?: "Mochi"

    /** The computer, as the app names it ("your Mac", "your PC"); null before pairing. */
    val host get() = if (paired) string("host") else null
    val title get() = string("title") ?: "Mochi & Claude"
    val text get() = string("text") ?: ""
    val art get() = string("art") ?: "idle"
    val frame get() = if (json.has("frame")) json.optInt("frame") else null
    val staleAtMs get() = long("staleAtMs")
    val restTitle get() = string("restTitle") ?: title
    val restText get() = string("restText") ?: text
    val restArt get() = string("restArt") ?: "idle"
    val sessionsTitle get() = string("sessionsTitle") ?: "Claude"
    val waitingKnown get() = json.optBoolean("waitingKnown", false)
    val waitingTitle get() = string("waitingTitle") ?: "Waiting for you"
    val emptyText get() = string("emptyText") ?: "Nothing waiting."
    val updatedMs get() = long("updatedMs")

    val sessions: List<Session>
        get() = objects("sessions").mapNotNull { row ->
            val project = row.optString("project").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            Session(project, row.optString("status"), row.optString("phase", "idle"))
        }

    val items: List<Item>
        get() = objects("items").mapNotNull { row ->
            val text = row.optString("text").takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            Item(
                kind = row.optString("kind", "gmail"),
                text = text,
                vip = row.optBoolean("vip", false),
                important = row.optBoolean("important", false),
                dueMs = if (row.has("dueMs")) row.optLong("dueMs") else null,
                leavesMs = if (row.has("leavesMs")) row.optLong("leavesMs") else null,
            )
        }

    private fun string(key: String): String? = if (json.isNull(key)) null else json.optString(key).takeIf { json.has(key) }

    private fun long(key: String): Long? = if (json.has(key) && !json.isNull(key)) json.optLong(key) else null

    private fun objects(key: String): List<JSONObject> {
        val array = json.optJSONArray(key) ?: JSONArray()
        return (0 until array.length()).mapNotNull { array.optJSONObject(it) }
    }

    companion object {
        /** `MochiHomeWidgetPlugin.PREFS` and `VIEW` in plugins/mochi_home_widget. */
        private const val PREFS = "mochi_home_widget"
        private const val VIEW = "view"

        fun load(context: Context): WidgetView? {
            val text = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(VIEW, null) ?: return null
            return try {
                WidgetView(JSONObject(text))
            } catch (error: Exception) {
                null
            }
        }
    }
}
