package com.cresca.app

import android.net.Uri
import android.util.Log
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException

/**
 * Lazy stream-URL resolution on ExoPlayer's loader thread (BitChord pattern).
 *
 * MediaItems carry stable `cresca://watch?v=<id>` URIs, so skip/tap is an
 * instant setMediaItem with zero network on the calling thread. The googlevideo
 * URL is resolved here, at first-byte time, where single-flight + disk urlCache
 * + videoId-keyed bytes usually make it instant. Non-cresca URIs (offline
 * files, DASH manifests) pass straight through to upstream.
 */
class ResolvingDataSource(
    private val upstreamFactory: DataSource.Factory
) : BaseDataSource(true), DataSource {

    companion object {
        private const val TAG = "ResolveDS"

        fun uriFor(videoId: String): Uri =
            Uri.parse("cresca://watch?v=$videoId")

        fun videoIdOf(uri: Uri?): String? = try {
            uri?.getQueryParameter("v")?.takeIf { it.length == 11 }
        } catch (e: Exception) {
            null
        }
    }

    private var delegate: DataSource? = null

    override fun open(dataSpec: DataSpec): Long {
        val videoId = videoIdOf(dataSpec.uri)
        val upstream = try {
            upstreamFactory.createDataSource()
        } catch (e: Exception) {
            throw IOException("upstream factory failed", e)
        }
        // Passthrough: not ours (offline file, manifest, http...).
        if (videoId == null) {
            delegate = upstream
            return upstream.open(dataSpec)
        }
        val t0 = try {
            android.os.SystemClock.elapsedRealtime()
        } catch (e: Exception) {
            0L
        }
        val url = try {
            runBlocking {
                withTimeoutOrNull(45_000L) {
                    YoutubeRepository.audioUrl("https://www.youtube.com/watch?v=$videoId")
                }
            }
        } catch (e: Exception) {
            null
        }?.takeIf { !it.isNullOrBlank() }
            ?: throw IOException("could not resolve audio stream for $videoId")
        try {
            Log.d(TAG, "resolved $videoId in ${try {
                android.os.SystemClock.elapsedRealtime() - t0
            } catch (e: Exception) {
                -1
            }}ms")
        } catch (e: Exception) {
        }
        delegate = upstream
        // Keep the videoId cache key: the signed URL changes per resolve,
        // the key must not (matches customCacheKey + precache writes).
        val keyed = try {
            dataSpec.withUri(Uri.parse(url))
        } catch (e: Exception) {
            DataSpec(Uri.parse(url), dataSpec.position, dataSpec.length, dataSpec.key)
        }
        return upstream.open(keyed)
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        return try {
            delegate?.read(buffer, offset, length) ?: -1
        } catch (e: Exception) {
            throw e
        }
    }

    override fun getUri(): Uri? {
        return try {
            delegate?.uri
        } catch (e: Exception) {
            null
        }
    }

    override fun getResponseHeaders(): Map<String, List<String>> {
        return try {
            delegate?.responseHeaders ?: emptyMap()
        } catch (e: Exception) {
            emptyMap()
        }
    }

    override fun close() {
        try {
            delegate?.close()
        } catch (e: Exception) {
        }
        delegate = null
    }
}

/** Factory pairing for the PlaybackService cache chain. */
class ResolvingDataSourceFactory(
    private val upstreamFactory: DataSource.Factory
) : DataSource.Factory {
    override fun createDataSource(): DataSource = ResolvingDataSource(upstreamFactory)
}
