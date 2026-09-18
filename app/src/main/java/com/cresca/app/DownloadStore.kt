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
    private const val SUBDIR = "Cresca"
    private const val EXT = ".m4a"

    // In-memory trackId -> downloadManagerId.
    private val memIds = ConcurrentHashMap<String, Long>()

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun dirFor(ctx: Context): File =
        File(ctx.getExternalFilesDir(Environment.DIRECTORY_MUSIC), SUBDIR)

    private fun fileNameFor(trackId: String): String =
        sanitize(trackId) + EXT

    // Read one persisted row; null when absent or corrupt.
    private fun readRow(ctx: Context, trackId: String): JSONObject? {
        // Check memory first so callers stay fast after enqueue.
        try {
            val raw = prefs(ctx).getString(trackId, null) ?: return null
            return JSONObject(raw)
        } catch (e: Exception) {
            return null
        }
    }

    // Persist id -> (downloadId, title, artist) as a JSON string.
    private fun writeRow(ctx: Context, track: YtTrack, downloadId: Long) {
        try {
            val obj = JSONObject()
            obj.put("downloadId", downloadId)
            obj.put("title", track.title)
            obj.put("artist", track.artist)
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
        val dest = SUBDIR + "/" + fileNameFor(track.id)
        val req = DownloadManager.Request(Uri.parse(audioUrl))
            .setTitle(track.title)
            .setDescription(track.artist)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalFilesDir(ctx, Environment.DIRECTORY_MUSIC, dest)
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(true)
        val id = mgr.enqueue(req)
        memIds[track.id] = id
        writeRow(ctx, track, id)
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
            val f = File(dirFor(ctx), fileNameFor(trackId))
            if (f.exists() && f.isFile) return f
            return null
        } catch (e: Exception) {
            return null
        }
    }

    fun listAll(ctx: Context): List<Pair<YtTrack, File>> {
        val dir = try { dirFor(ctx) } catch (e: Exception) { return emptyList() }
        val files = try {
            dir.listFiles { f -> f.isFile && f.name.endsWith(EXT, ignoreCase = true) }
                ?: return emptyList()
        } catch (e: Exception) {
            return emptyList()
        }
        val out = ArrayList<Pair<YtTrack, File>>(files.size)
        for (f in files) {
            try {
                val base = f.nameWithoutExtension
                // Filename is sanitized track id; use it as the id.
                val trackId = base
                val row = readRow(ctx, trackId)
                val title = row?.optString("title", null)?.takeIf { it.isNotEmpty() } ?: base
                val artist = row?.optString("artist", null)?.takeIf { it.isNotEmpty() } ?: "Unknown Artist"
                // Keep persisted download id warm in memory when present.
                try {
                    val did = row?.optLong("downloadId", Long.MIN_VALUE) ?: Long.MIN_VALUE
                    if (did != Long.MIN_VALUE) memIds[trackId] = did
                } catch (e: Exception) { /* ignore */ }
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
        // Remove the file when present.
        try {
            val f = File(dirFor(ctx), fileNameFor(trackId))
            if (f.exists()) {
                try { f.delete() } catch (e: Exception) { /* ignore */ }
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
            if ((ch in 'A'..'Z') || (ch in 'a'..'z') || (ch in '0'..'9') || ch == ' ' || ch == '_' || ch == '-') {
                kept.append(ch)
            }
        }
        val s = kept.toString().trim().take(60).trim()
        if (s.isEmpty()) return "track"
        return s
    }
}
