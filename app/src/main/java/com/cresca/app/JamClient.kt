package com.cresca.app

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * JAM listen-together client (Spotify-Jam-style).
 *
 * Server-friendly by design: this socket carries ~200-byte JSON sync
 * notes only (track id + position + play/pause + queue ops). Audio is
 * NEVER relayed — every phone streams YouTube directly, so the server
 * stays at ~0% CPU and a few KB per room.
 *
 * One authority rule keeps it smooth: the HOST's player is the clock.
 * Guests mirror host state; their taps become `control` wishes the host
 * executes (no clock fights, no extra server logic).
 */

data class JamTrack(
    val id: String = "",
    val title: String = "",
    val artist: String = "",
    val thumb: String = "",
    val url: String = ""
) {
    companion object {
        fun from(t: YtTrack): JamTrack = JamTrack(
            id = t.id.take(16),
            title = t.title.take(120),
            artist = t.artist.take(80),
            thumb = t.thumbUrl.take(300),
            url = t.watchUrl.take(300)
        )
    }

    fun toYtTrack(): YtTrack = YtTrack(
        id = id,
        title = title.ifBlank { "Unknown" },
        artist = artist.ifBlank { "YouTube" },
        thumbUrl = thumb,
        watchUrl = url.ifBlank { "https://music.youtube.com/watch?v=$id" }
    )
}

data class JamMember(val id: String, val name: String, val host: Boolean)

/**
 * Deep-link parking (cresca://jam/&lt;CODE&gt;): the Activity parks the
 * code here, the player sheet consumes it. Mirrors SpotifyAuth.Link.
 */
object JamLink {
    var code: String? by mutableStateOf(null)
}

/**
 * `st` is the SERVER's clock at send time — the one shared timebase the
 * whole room measures against. `at` is kept for older servers.
 */
data class JamNow(val track: JamTrack, val pos: Long, val playing: Boolean, val at: Long, val st: Long = 0L)
data class JamControl(val action: String, val id: String = "", val pos: Long = 0L, val by: String = "")

class JamClient(
    private val scope: CoroutineScope,
    appContext: Context
) {
    companion object {
        private const val TAG = "Jam"
        private const val PREFS = "jam_prefs"
        private const val MIN_STATE_MS = 800L
        private const val MIN_QUEUE_MS = 1000L
        // The JAM box. Internal only — never shown in the UI. http/https
        // schemes are normalized to ws/wss on connect.
        const val DEFAULT_SERVER = "http://209.126.81.22:13009"
    }

    // Offset of the SERVER clock vs this phone (serverNow = local + offset),
    // NTP-style: min-RTT sample wins, so jitter never poisons the estimate.
    private val _offset = MutableStateFlow(0L)
    val offset = _offset.asStateFlow()
    private var bestRtt = Long.MAX_VALUE
    private var bestOffset = 0L
    private var pingGen = 0L
    private var pingSentAt = 0L

    fun serverNow(): Long {
        return try {
            System.currentTimeMillis() + _offset.value
        } catch (e: Exception) {
            System.currentTimeMillis()
        }
    }

    // Expected room position: host pos + time elapsed on the SHARED server
    // clock. Phone-clock skew drops out entirely.
    fun expectedPos(s: JamNow): Long {
        return try {
            if (!s.playing) return s.pos
            val st = if (s.st > 0L) s.st else s.at
            val dt = serverNow() - st
            if (dt < 0L || dt > 30_000L) s.pos else s.pos + dt
        } catch (e: Exception) {
            s.pos
        }
    }

    private fun startPingLoop() {
        pingGen++
        val g = pingGen
        bestRtt = Long.MAX_VALUE
        scope.launch {
            try {
                // Fast converge on join, then a cheap 10s keep-warm.
                repeat(5) {
                    if (g != pingGen || !wantConnected) return@launch
                    sendPing()
                    delay(400)
                }
                while (g == pingGen && wantConnected) {
                    sendPing()
                    delay(10_000)
                }
            } catch (e: Exception) {
            }
        }
    }

    private fun sendPing() {
        try {
            pingSentAt = System.currentTimeMillis()
            ws?.send(JSONObject().put("type", "ping").put("t", pingSentAt).toString())
        } catch (e: Exception) {
        }
    }

    private fun onPong(t: Long, st: Long) {
        try {
            val now = System.currentTimeMillis()
            if (t != pingSentAt) return
            val rtt = (now - t).coerceAtLeast(0L)
            // Classic NTP offset: server time minus our mid-flight time.
            val off = st - (t + rtt / 2)
            if (rtt < bestRtt) {
                bestRtt = rtt
                bestOffset = off
                _offset.value = off
            }
        } catch (e: Exception) {
        }
    }

    private val prefs = try {
        appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    } catch (e: Exception) {
        null
    }

    private val http = try {
        OkHttpClient.Builder()
            .pingInterval(25, TimeUnit.SECONDS)
            .connectTimeout(10, TimeUnit.SECONDS)
            .build()
    } catch (e: Exception) {
        OkHttpClient()
    }

    private var ws: WebSocket? = null
    private var wantConnected = false
    private var retryJob: Job? = null
    // Bounded retries: failures re-arm from zero (socket callbacks don't
    // know the attempt count), so the count lives here, not in params.
    private var retryAttempt = 0
    // Our own member id (from `joined.you`): used to track host migration
    // when the old host leaves and the room promotes us.
    private var myId = ""
    private var lastUrl = ""
    private var lastName = ""
    private var lastCreate = true
    private var lastCode = ""
    private var lastStateSent = 0L
    private var lastQueueSent = 0L

    private val _connected = MutableStateFlow(false)
    private val _code = MutableStateFlow("")
    private val _isHost = MutableStateFlow(false)
    private val _members = MutableStateFlow<List<JamMember>>(emptyList())
    private val _now = MutableStateFlow<JamNow?>(null)
    private val _queue = MutableStateFlow<List<JamTrack>>(emptyList())
    private val _queueCur = MutableStateFlow("")
    private val _guestAllowed = MutableStateFlow(false)
    private val _error = MutableStateFlow<String?>(null)
    private val _controls = MutableSharedFlow<JamControl>(extraBufferCapacity = 16)
    private val _adds = MutableSharedFlow<Pair<JamTrack, String>>(extraBufferCapacity = 16)
    // Host inbox: guests asking for a fresh state (stale join, retry hold).
    private val _syncRequests = MutableSharedFlow<String>(extraBufferCapacity = 8)
    // Deep-link code waiting to be joined (set by openLink, read by sheet).
    private val _pendingCode = MutableStateFlow("")
    val pendingCode = _pendingCode.asStateFlow()
    private var lastSyncSent = 0L

    val connected = _connected.asStateFlow()
    val code = _code.asStateFlow()
    val isHost = _isHost.asStateFlow()
    val members = _members.asStateFlow()
    val now = _now.asStateFlow()
    val queue = _queue.asStateFlow()
    val queueCur = _queueCur.asStateFlow()
    val guestAllowed = _guestAllowed.asStateFlow()
    val error = _error.asStateFlow()
    val controls = _controls.asSharedFlow()
    val adds = _adds.asSharedFlow()
    val syncRequests = _syncRequests.asSharedFlow()

    fun openLink(code: String) {
        _pendingCode.value = code.trim().uppercase().take(6)
    }

    fun consumeLink(): String {
        val c = _pendingCode.value
        _pendingCode.value = ""
        return c
    }

    // Server is internal (DEFAULT_SERVER) — the UI never asks for it.
    val serverUrl = MutableStateFlow(DEFAULT_SERVER)
    val myName = MutableStateFlow(
        try {
            prefs?.getString(
                "jam_name",
                "Guest-" + (1000 + (Math.random() * 9000).toInt())
            ) ?: "Guest"
        } catch (e: Exception) {
            "Guest"
        }
    )

    fun saveName(name: String) {
        val n = name.trim().take(24).ifBlank { myName.value }
        myName.value = n
        try {
            prefs?.edit()?.putString("jam_name", n)?.apply()
        } catch (e: Exception) {
        }
    }

    fun start(name: String) {
        connect(DEFAULT_SERVER, name, create = true, code = "")
    }

    fun join(name: String, code: String) {
        connect(DEFAULT_SERVER, name, create = false, code = code.trim().uppercase())
    }

    private fun connect(url: String, name: String, create: Boolean, code: String) {
        try { retryJob?.cancel() } catch (e: Exception) { }
        try { ws?.close(1000, "reconnect") } catch (e: Exception) { }
        ws = null
        _error.value = null
        lastUrl = url.trim()
        lastName = name.trim().take(24).ifBlank { "Guest" }
        lastCreate = create
        lastCode = code.trim().uppercase()
        saveName(lastName)
        if (lastUrl.isBlank()) {
            _error.value = "Enter your JAM server address first"
            return
        }
        if (!create && lastCode.length != 6) {
            _error.value = "JAM code is 6 letters"
            return
        }
        wantConnected = true
        retryAttempt = 0
        openSocket()
    }

    private fun openSocket() {
        if (!wantConnected) return
        val wsUrl = try {
            var u = lastUrl.trim()
            if (u.startsWith("http://")) u = "ws://" + u.removePrefix("http://")
            else if (u.startsWith("https://")) u = "wss://" + u.removePrefix("https://")
            if (!u.startsWith("ws://") && !u.startsWith("wss://")) u = "ws://$u"
            u.trimEnd('/')
        } catch (e: Exception) {
            _error.value = "Bad server address"
            wantConnected = false
            return
        }
        try {
            val req = Request.Builder().url(wsUrl).build()
            ws = http.newWebSocket(req, listener)
        } catch (e: Exception) {
            Log.w(TAG, "connect failed", e)
            scheduleRetry("Can't reach server")
        }
    }

    private fun scheduleRetry(msg: String) {
        if (!wantConnected) return
        if (retryAttempt >= 4) {
            _connected.value = false
            _error.value = msg + " — tap Retry"
            wantConnected = false
            return
        }
        _error.value = msg + " — retrying…"
        val waitMs = longArrayOf(1000L, 2000L, 4000L, 8000L)[retryAttempt.coerceIn(0, 3)]
        retryAttempt++
        retryJob = scope.launch {
            try {
                delay(waitMs)
            } catch (e: Exception) { }
            openSocket()
        }
    }

    fun retry() {
        if (_connected.value) return
        wantConnected = true
        retryAttempt = 0
        _error.value = null
        openSocket()
    }

    /** Guest/host leaves but keeps listening locally. Host `endJam()` kills the room. */
    fun leave() {
        wantConnected = false
        try { retryJob?.cancel() } catch (e: Exception) { }
        try { ws?.send("""{"type":"leave"}""") } catch (e: Exception) { }
        try { ws?.close(1000, "leave") } catch (e: Exception) { }
        ws = null
        reset()
    }

    fun endJam() {
        wantConnected = false
        try { retryJob?.cancel() } catch (e: Exception) { }
        try { ws?.send("""{"type":"end"}""") } catch (e: Exception) { }
        try { ws?.close(1000, "end") } catch (e: Exception) { }
        ws = null
        reset()
    }

    private fun reset() {
        myId = ""
        pingGen++ // stop the clock-sync loop
        bestRtt = Long.MAX_VALUE
        _connected.value = false
        _code.value = ""
        _isHost.value = false
        _members.value = emptyList()
        _now.value = null
        _queue.value = emptyList()
        _queueCur.value = ""
        _guestAllowed.value = false
    }

    // ---- Host sends (throttled so a busy host can't spam the box) ----

    fun sendState(track: YtTrack, pos: Long, playing: Boolean, force: Boolean = false) {
        if (!_connected.value || !_isHost.value) return
        val t = System.currentTimeMillis()
        if (!force && t - lastStateSent < MIN_STATE_MS) return
        lastStateSent = t
        try {
            val o = JSONObject()
            o.put("type", "state")
            if (force) o.put("force", true)
            val jt = JamTrack.from(track)
            val tr = JSONObject()
            tr.put("id", jt.id)
            tr.put("title", jt.title)
            tr.put("artist", jt.artist)
            tr.put("thumb", jt.thumb)
            tr.put("url", jt.url)
            o.put("track", tr)
            o.put("pos", pos.coerceAtLeast(0L))
            o.put("playing", playing)
            ws?.send(o.toString())
        } catch (e: Exception) {
        }
    }

    fun sendQueue(tracks: List<YtTrack>, curId: String) {
        if (!_connected.value || !_isHost.value) return
        val t = System.currentTimeMillis()
        if (t - lastQueueSent < MIN_QUEUE_MS) return
        lastQueueSent = t
        try {
            val o = JSONObject()
            o.put("type", "queue")
            val arr = JSONArray()
            for (jt in tracks.take(60)) {
                val c = JamTrack.from(jt)
                val tr = JSONObject()
                tr.put("id", c.id)
                tr.put("title", c.title)
                tr.put("artist", c.artist)
                tr.put("thumb", c.thumb)
                tr.put("url", c.url)
                arr.put(tr)
            }
            o.put("tracks", arr)
            o.put("cur", curId.take(16))
            ws?.send(o.toString())
        } catch (e: Exception) {
        }
    }

    fun sendGuestAllowed(on: Boolean) {
        if (!_connected.value || !_isHost.value) return
        try {
            ws?.send(JSONObject().put("type", "allow").put("on", on).toString())
        } catch (e: Exception) {
        }
    }

    // ---- Guest sends (tiny wishes; the host executes them) ----

    fun sendQueueAdd(track: YtTrack) {
        if (!_connected.value) return
        try {
            val jt = JamTrack.from(track)
            val o = JSONObject()
            o.put("type", "add")
            val tr = JSONObject()
            tr.put("id", jt.id)
            tr.put("title", jt.title)
            tr.put("artist", jt.artist)
            tr.put("thumb", jt.thumb)
            tr.put("url", jt.url)
            o.put("track", tr)
            ws?.send(o.toString())
        } catch (e: Exception) {
        }
    }

    fun sendControl(action: String, id: String = "", pos: Long = 0L) {
        if (!_connected.value || _isHost.value) return
        try {
            ws?.send(
                JSONObject().put("type", "control")
                    .put("action", action.take(16))
                    .put("id", id.take(16))
                    .put("pos", pos.coerceAtLeast(0L)).toString()
            )
        } catch (e: Exception) {
        }
    }

    /** Fresh-state plea (stale join snapshot, retry hold). Floored 10 s. */
    fun sendSyncRequest() {
        if (!_connected.value || _isHost.value) return
        val t = System.currentTimeMillis()
        if (t - lastSyncSent < 10_000L) return
        lastSyncSent = t
        try {
            ws?.send(JSONObject().put("type", "sync_req").toString())
        } catch (e: Exception) {
        }
    }

    // ---- Wire parsing ----

    private val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            try {
                val o = JSONObject()
                if (lastCreate) {
                    o.put("type", "create")
                    o.put("name", lastName)
                } else {
                    o.put("type", "join")
                    o.put("code", lastCode)
                    o.put("name", lastName)
                }
                webSocket.send(o.toString())
                startPingLoop()
            } catch (e: Exception) {
                scheduleRetry("Couldn't start JAM")
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            if (text.length > 32 * 1024) return
            scope.launch {
                try {
                    handle(JSONObject(text))
                } catch (e: Exception) {
                }
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            Log.w(TAG, "ws failure: ${t.message}")
            ws = null
            _connected.value = false
            scheduleRetry("Connection lost")
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            if (ws === webSocket) ws = null
            // Server closing us after `end`/`leave` is normal, not an error.
            if (wantConnected) {
                _connected.value = false
                scheduleRetry("Connection closed")
            }
        }
    }

    private fun handle(o: JSONObject) {
        when (o.optString("type")) {
            "created" -> {
                _code.value = o.optString("code").uppercase()
            }
            "joined" -> {
                _code.value = o.optString("code").uppercase()
                myId = o.optString("you")
                val host = o.optString("host")
                _isHost.value = myId.isNotBlank() && myId == host
                retryAttempt = 0 // healthy socket: reset the retry budget
                // Host flag is confirmed by the members list below; open optimistically.
                _connected.value = true
                _error.value = null
            }
            "members" -> {
                try {
                    val arr = o.optJSONArray("members")
                    val host = o.optString("host")
                    val list = ArrayList<JamMember>()
                    if (arr != null) {
                        for (i in 0 until arr.length()) {
                            val m = arr.optJSONObject(i) ?: continue
                            val id = m.optString("id")
                            if (id.isBlank()) continue
                            list.add(JamMember(id, m.optString("name", "Guest"), id == host))
                        }
                    }
                    _members.value = list
                    // Host migration: the old host left and the room promoted
                    // someone (possibly us) — follow the flag, not the past.
                    if (myId.isNotBlank()) _isHost.value = (host == myId)
                } catch (e: Exception) {
                }
            }
            "host" -> {
                // Host migrated (old host left): refresh host flags.
                try {
                    val host = o.optString("host")
                    _members.value = _members.value.map { it.copy(host = it.id == host) }
                    if (myId.isNotBlank()) _isHost.value = (host == myId)
                } catch (e: Exception) {
                }
            }
            "state" -> {
                try {
                    val s = o.optJSONObject("state") ?: return
                    val tr = s.optJSONObject("track") ?: return
                    val jt = JamTrack(
                        id = tr.optString("id"),
                        title = tr.optString("title"),
                        artist = tr.optString("artist"),
                        thumb = tr.optString("thumb"),
                        url = tr.optString("url")
                    )
                    if (jt.id.isBlank()) return
                    _now.value = JamNow(
                        track = jt,
                        pos = s.optLong("pos"),
                        playing = s.optBoolean("playing"),
                        at = s.optLong("at", System.currentTimeMillis()),
                        st = s.optLong("st", 0L)
                    )
                } catch (e: Exception) {
                }
            }
            "queue" -> {
                try {
                    val arr = o.optJSONArray("tracks")
                    val list = ArrayList<JamTrack>()
                    if (arr != null) {
                        for (i in 0 until arr.length().coerceAtMost(60)) {
                            val tr = arr.optJSONObject(i) ?: continue
                            val id = tr.optString("id")
                            if (id.isBlank() || list.any { it.id == id }) continue
                            list.add(
                                JamTrack(
                                    id = id,
                                    title = tr.optString("title"),
                                    artist = tr.optString("artist"),
                                    thumb = tr.optString("thumb"),
                                    url = tr.optString("url")
                                )
                            )
                        }
                    }
                    _queue.value = list
                    _queueCur.value = o.optString("cur")
                } catch (e: Exception) {
                }
            }
            "add" -> {
                // Only the host receives these: a guest's song suggestion.
                try {
                    val tr = o.optJSONObject("track") ?: return
                    val jt = JamTrack(
                        id = tr.optString("id"),
                        title = tr.optString("title"),
                        artist = tr.optString("artist"),
                        thumb = tr.optString("thumb"),
                        url = tr.optString("url")
                    )
                    if (jt.id.isBlank()) return
                    _adds.tryEmit(Pair(jt, o.optString("by", "Guest")))
                } catch (e: Exception) {
                }
            }
            "control" -> {
                // Only the host receives these: guest transport wishes.
                try {
                    _controls.tryEmit(
                        JamControl(
                            action = o.optString("action"),
                            id = o.optString("id"),
                            pos = o.optLong("pos"),
                            by = o.optString("by", "Guest")
                        )
                    )
                } catch (e: Exception) {
                }
            }
            "allow" -> {
                _guestAllowed.value = o.optBoolean("on")
            }
            "sync_req" -> {
                // Only the host receives these: answer with a fresh state.
                try {
                    _syncRequests.tryEmit(o.optString("by", "Guest"))
                } catch (e: Exception) {
                }
            }
            "pong" -> {
                onPong(o.optLong("t"), o.optLong("st"))
            }
            "ended" -> {
                wantConnected = false
                try { ws?.close(1000, "ended") } catch (e: Exception) { }
                ws = null
                val why = o.optString("why").ifBlank { "JAM ended" }
                reset()
                _error.value = why
            }
            "left" -> { /* ack, ignore */ }
            "error" -> {
                val msg = o.optString("msg").ifBlank { "Server error" }
                // Join/create rejections happen pre-connect: stop retrying.
                if (!_connected.value) wantConnected = false
                _error.value = msg
            }
        }
    }
}
