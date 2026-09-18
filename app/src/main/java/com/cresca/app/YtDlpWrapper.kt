package com.cresca.app

import android.content.Context
import java.io.File

/**
 * yt-dlp on Android = Seal-app method: ship a prebuilt aarch64 binary,
 * copy from assets to filesDir, chmod +x, run via ProcessBuilder.
 * Do NOT try `pip install yt-dlp` inside the app (needs Chaquopy, ~100MB+).
 *
 * 1. Download from https://github.com/yt-dlp/yt-dlp/releases
 *    + ffmpeg Android build, put in app/src/main/assets/
 * 2. Call installIfNeeded() once, then resolveStreamUrl().
 */
object YtDlpWrapper {
    fun binaryFile(ctx: Context): File = File(ctx.filesDir, "yt-dlp")

    fun buildCommand(videoId: String, cookieFile: File?): List<String> {
        // --print urls gives direct stream for Media3 ExoPlayer
        return buildList {
            add("yt-dlp") // replaced with absolute path at runtime
            add("--no-playlist")
            add("--extractor-args"); add("youtube:player_client=android_music")
            if (cookieFile != null) { add("--cookies"); add(cookieFile.absolutePath) }
            add("--print"); add("urls")
            add("https://music.youtube.com/watch?v=$videoId")
        }
    }
}
