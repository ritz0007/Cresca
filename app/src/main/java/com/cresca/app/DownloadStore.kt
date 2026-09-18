package com.cresca.app

import android.app.DownloadManager
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Environment
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap

object DownloadStore {
    private const val PREFS = "dlmap"
    private const val APP_PREFS = "cresca_prefs"
    private const val KEY_LOCATION = "dl_location"
    private const val SUBDIR = "Cresca"
    private const val EXT = ".m4a"

    // In-memory trackId -> downloadManagerId.
    private val memIds = ConcurrentHashMap<String, Long>()

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // "app" (private app folder) or "device" (public Music folder).
    fun location(ctx: Context): String {
        return try {
            ctx.getSharedPreferences(APP_PREFS, Context.MODE_PRIVATE)
                .getString(KEY_LOCATION, "app") ?: "app"
        } catch (e: Exception) {
            "app"
        }
    }

    fun setLocation(ctx: Context, value: String) {
        try {
            ctx.getSharedPreferences(APP_PREFS, Context.MODE_PRIVATE)
                .edit().putString(KEY_LOCATION, value).apply()
        } catch (e: Exception) {
        }
    }

    private fun appDir(ctx: Context): File =
        File(ctx.getExternalFilesDir(Environment.DIRECTORY_MUSIC), SUBDIR)

    private fun publicDir(): File? {
        return try {
            @Suppress("DEPRECATION")
            File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC),
                SUBDIR
            )
        } catch (e: Exception) {
            null
        }
    }

    private fun dirsFor(ctx: Context): List<File> {
        val out = ArrayList<File>(2)
        try {
            out.add(appDir(ctx))
        } catch (e: Exception) {
        }
        try {
            val p = publicDir()
            if (p != null) {
                out.add(p)
            }
        } catch (e: Exception) {
        }
        return out
    }

    // Human file name: "Artist - Title". Falls back to the id.
    private fun fileNameFor(track: YtTrack): String {
        val base = (track.artist.trim() + " - " + track.title.trim()).trim()
        val clean = sanitize(if (base == "-") track.id else base)
        return clean + EXT
    }

    // Read one persisted row; null when absent or corrupt.
    private fun readRow(ctx: Context, trackId: String): JSONObject? {
        try {
            val raw = prefs(ctx).getString(trackId, null) ?: return null
            return JSONObject(raw)
        } catch (e: Exception) {
            return null
        }
    }

    // Persist id -> (downloadId, title, artist, name, public) as JSON.
    private fun writeRow(ctx: Context, track: YtTrack, name: String, pub: Boolean, downloadId: Long) {
        try {
            val obj = JSONObject()
            obj.put("downloadId", downloadId)
            obj.put("title", track.title)
            obj.put("artist", track.artist)
            obj.put("name", name)
            obj.put("public", pub)
            prefs(ctx).edit().putString(track.id, obj.toString()).apply()
        } catch (e: Exception) {
            // Ignore persistence failure; memory map still works.
        }
    }

    fun downloadIdFor(trackId: String): Long? {
        // Fast path: in-memory map.
        memIds[trackId]?.let { return it }
        return null
    }

    // Private helper that also consults disk when memory misses.
    private fun downloadIdFor(ctx: Context, trackId: String): Long? {
        memIds[trackId]?.let { return it }
        val row = readRow(ctx, trackId) ?: return null
        return try {
            val id = row.optLong("downloadId", Long.MIN_VALUE)
            if (id == Long.MIN_VALUE) null else {
                memIds[trackId] = id
                id
            }
        } catch (e: Exception) {
            null
        }
    }

    fun enqueue(ctx: Context, track: YtTrack, audioUrl: String): Long {
        val mgr = ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val name = fileNameFor(track)
        val pub = location(ctx) == "device"
        val req = DownloadManager.Request(Uri.parse(audioUrl))
            .setTitle(track.title)
            .setDescription(track.artist)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(true)
        if (pub) {
            @Suppress("DEPRECATION")
            req.setDestinationInExternalPublicDir(Environment.DIRECTORY_MUSIC, SUBDIR + "/" + name)
        } else {
            req.setDestinationInExternalFilesDir(ctx, Environment.DIRECTORY_MUSIC, SUBDIR + "/" + name)
        }
        val id = mgr.enqueue(req)
        memIds[track.id] = id
        writeRow(ctx, track, name, pub, id)
        return id
    }

    fun progress(ctx: Context, downloadId: Long): Int {
        val mgr = ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        var c: Cursor? = null
        try {
            c = mgr.query(DownloadManager.Query().setFilterById(downloadId))
            if (c == null || !c.moveToFirst()) return -1
            val statusIdx = c.getColumnIndex(DownloadManager.COLUMN_STATUS)
            val doneIdx = c.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
            val totalIdx = c.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
            val status = if (statusIdx >= 0) c.getInt(statusIdx) else -1
            if (status == DownloadManager.STATUS_SUCCESSFUL) return 100
            if (status == DownloadManager.STATUS_FAILED) return -1
            if (doneIdx < 0 || totalIdx < 0) return 0
            val done = c.getLong(doneIdx)
            val total = c.getLong(totalIdx)
            if (total <= 0L) return 0
            val pct = ((done * 100L) / total).toInt()
            if (pct < 0) return 0
            if (pct > 100) return 100
            return pct
        } catch (e: Exception) {
            return -1
        } finally {
            try { c?.close() } catch (e: Exception) { /* ignore */ }
        }
    }

    fun isDownloaded(ctx: Context, trackId: String): Boolean {
        return fileFor(ctx, trackId) != null
    }

    fun fileFor(ctx: Context, trackId: String): File? {
        try {
            val row = readRow(ctx, trackId)
            val name = row?.optString("name", null)?.takeIf { it.isNotEmpty() }
            if (name != null) {
                // New layout: exact stored file name, either location.
                for (d in dirsFor(ctx)) {
                    try {
                        val f = File(d, name)
                        if (f.exists() && f.isFile) return f
                    } catch (e: Exception) {
                    }
                }
            }
            // Legacy layout: sanitized id as file name.
            val legacy = sanitize(trackId) + EXT
            for (d in dirsFor(ctx)) {
                try {
                    val f = File(d, legacy)
                    if (f.exists() && f.isFile) return f
                } catch (e: Exception) {
                }
            }
            return null
        } catch (e: Exception) {
            return null
        }
    }

    fun listAll(ctx: Context): List<Pair<YtTrack, File>> {
        // Index rows by stored file name for lookup.
        val byName = HashMap<String, Pair<String, JSONObject>>()
        try {
            val all = prefs(ctx).all
            for ((key, value) in all) {
                try {
                    if (value is String) {
                        val o = JSONObject(value)
                        val nm = o.optString("name", "")
                        if (nm.isNotEmpty()) {
                            byName[nm] = Pair(key, o)
                        }
                    }
                } catch (e: Exception) {
                }
            }
        } catch (e: Exception) {
        }
        val out = ArrayList<Pair<YtTrack, File>>()
        for (d in dirsFor(ctx)) {
            val files = try {
                d.listFiles { f -> f.isFile && f.name.endsWith(EXT, ignoreCase = true) }
                    ?: continue
            } catch (e: Exception) {
                continue
            }
            for (f in files) {
                try {
                    val hit = byName[f.name]
                    val trackId: String
                    val title: String
                    val artist: String
                    if (hit != null) {
                        trackId = hit.first
                        title = hit.second.optString("title", "").ifEmpty { f.nameWithoutExtension }
                        artist = hit.second.optString("artist", "").ifEmpty { "Unknown Artist" }
                        try {
                            val did = hit.second.optLong("downloadId", Long.MIN_VALUE)
                            if (did != Long.MIN_VALUE) memIds[trackId] = did
                        } catch (e: Exception) { /* ignore */ }
                    } else {
                        // Legacy id-named file or unknown origin.
                        trackId = f.nameWithoutExtension
                        title = f.nameWithoutExtension
                        artist = "Unknown Artist"
                    }
                    val track = YtTrack(
                        id = trackId,
                        title = title,
                        artist = artist,
                        thumbUrl = "",
                        watchUrl = "",
                        localPath = f.absolutePath
                    )
                    out.add(track to f)
                } catch (e: Exception) {
                    // Skip unreadable entries.
                }
            }
        }
        return out
    }

    fun delete(ctx: Context, trackId: String) {
        // Remove DownloadManager entry when known.
        try {
            val did = downloadIdFor(ctx, trackId)
            if (did != null) {
                val mgr = ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                try { mgr.remove(did) } catch (e: Exception) { /* ignore */ }
            }
        } catch (e: Exception) { /* ignore */ }
        // Remove the file when present (any known location + legacy name).
        try {
            fileFor(ctx, trackId)?.let {
                try { it.delete() } catch (e: Exception) { /* ignore */ }
            }
        } catch (e: Exception) { /* ignore */ }
        // Drop memory + persisted rows.
        memIds.remove(trackId)
        try {
            prefs(ctx).edit().remove(trackId).apply()
        } catch (e: Exception) { /* ignore */ }
    }

    fun sanitize(name: String): String {
        val kept = StringBuilder(name.length)
        for (ch in name) {
            if ((ch in 'A'..'Z') || (ch in 'a'..'z') || (ch in '0'..'9') || ch == ' ' || ch == '_' || ch == '-' || ch == '(' || ch == ')' || ch == '&') {
                kept.append(ch)
            }
        }
        val s = kept.toString().trim().take(80).trim()
        if (s.isEmpty()) return "track"
        return s
    }
}
