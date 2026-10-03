package com.cresca.app

import android.content.Intent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExitToApp
import androidx.compose.material.icons.filled.Group
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/**
 * JAM sheet: start/join + room view. Lives off the player (like Queue).
 * Everything here is tiny JSON over one socket; audio always streams
 * direct from YouTube on each phone, never through the server.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JamSheet(
    jam: JamClient,
    current: YtTrack?,
    localQueue: List<YtTrack>,
    localCurId: String?,
    canControl: Boolean,
    onHostPlayId: (String) -> Unit,
    onAddCurrent: () -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val connected by jam.connected.collectAsState()
    val code by jam.code.collectAsState()
    val isHost by jam.isHost.collectAsState()
    val members by jam.members.collectAsState()
    val queue by jam.queue.collectAsState()
    val queueCur by jam.queueCur.collectAsState()
    val guestAllowed by jam.guestAllowed.collectAsState()
    val error by jam.error.collectAsState()
    val linkCode by jam.pendingCode.collectAsState()
    // Deep link / QR scan: auto-join once with the saved name (F2).
    LaunchedEffect(linkCode, connected) {
        if (linkCode.length == 6 && !connected) {
            try {
                val c = jam.consumeLink()
                if (c.length == 6) jam.join(jam.myName.value, c)
            } catch (e: Exception) {
            }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Filled.Group, contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(26.dp)
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "JAM",
                        style = MaterialTheme.typography.titleLarge.copy(
                            fontWeight = FontWeight.Bold
                        )
                    )
                    if (connected) {
                        Spacer(Modifier.width(8.dp))
                        Box(
                            Modifier.size(8.dp).clip(CircleShape)
                                .background(MaterialTheme.colorScheme.primary)
                        )
                    }
                }
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Filled.Close, contentDescription = "Close")
                }
            }

            if (!connected) {
                JamJoinForm(
                    jam = jam,
                    error = error,
                    initialCode = linkCode,
                    onStart = { name -> jam.start(name) },
                    onJoin = { name, joinCode -> jam.join(name, joinCode) },
                    onRetry = { jam.retry() }
                )
            } else {
                JamRoom(
                    code = code,
                    isHost = isHost,
                    members = members,
                    queue = queue,
                    queueCur = queueCur,
                    localQueue = localQueue,
                    localCurId = localCurId,
                    current = current,
                    guestAllowed = guestAllowed,
                    canControl = canControl,
                    error = error,
                    onShare = {
                        try {
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(
                                    Intent.EXTRA_TEXT,
                                    "Join my Cresca JAM!\n" +
                                        "Link: cresca://jam/$code\n" +
                                        "Code: $code (enter it in Player → JAM if the link doesn't open)"
                                )
                            }
                            context.startActivity(Intent.createChooser(send, "Share JAM"))
                        } catch (e: Exception) {
                        }
                    },
                    onToggleGuests = { jam.sendGuestAllowed(it) },
                    onTapTrack = { id -> onHostPlayId(id) },
                    onAddCurrent = onAddCurrent,
                    onLeave = { jam.leave(); onDismiss() },
                    onEnd = { jam.endJam(); onDismiss() }
                )
            }
            Spacer(Modifier.height(28.dp))
        }
    }
}

@Composable
private fun JamJoinForm(
    jam: JamClient,
    error: String?,
    initialCode: String = "",
    onStart: (String) -> Unit,
    onJoin: (String, String) -> Unit,
    onRetry: () -> Unit
) {
    var name by remember { mutableStateOf(jam.myName.value) }
    var joinCode by remember(initialCode) { mutableStateOf(initialCode) }

    Text(
        "Listen together, live. One phone hosts, friends join with a code — " +
            "everyone hears the same song at the same time.",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(vertical = 8.dp)
    )
    OutlinedTextField(
        value = name, onValueChange = { name = it.take(24) },
        label = { Text("Your name") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)
    )
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        OutlinedTextField(
            value = joinCode,
            onValueChange = { joinCode = it.uppercase().filter { c -> c.isLetterOrDigit() }.take(6) },
            label = { Text("Code") },
            placeholder = { Text("ABC123") },
            singleLine = true,
            modifier = Modifier.weight(1f)
        )
        Spacer(Modifier.width(8.dp))
        Button(
            onClick = { onJoin(name, joinCode) },
            enabled = joinCode.length == 6
        ) { Text("Join") }
    }
    Button(
        onClick = { onStart(name) },
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)
    ) { Text("Start a JAM") }
    if (error != null) {
        Text(
            error,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 6.dp)
        )
        TextButton(onClick = onRetry) { Text("Retry") }
    }
}

@Composable
private fun JamRoom(
    code: String,
    isHost: Boolean,
    members: List<JamMember>,
    queue: List<JamTrack>,
    queueCur: String,
    localQueue: List<YtTrack>,
    localCurId: String?,
    current: YtTrack?,
    guestAllowed: Boolean,
    canControl: Boolean,
    error: String?,
    onShare: () -> Unit,
    onToggleGuests: (Boolean) -> Unit,
    onTapTrack: (String) -> Unit,
    onAddCurrent: () -> Unit,
    onLeave: () -> Unit,
    onEnd: () -> Unit
) {
    // Host sees its own live queue. Guests ALWAYS see the room snapshot
    // (falling back to the local queue here showed guests the wrong list
    // in fresh rooms whose host hadn't snapshotted yet).
    val shown: List<Triple<String, String, String>> = remember(queue, localQueue, isHost) {
        try {
            if (isHost) {
                localQueue.map { Triple(it.id, it.title, it.displayArtist()) }
            } else {
                queue.map {
                    Triple(
                        it.id, it.title.ifBlank { "Unknown" },
                        it.artist.ifBlank { "YouTube" }
                    )
                }
            }
        } catch (e: Exception) {
            emptyList()
        }
    }
    val curId = if (isHost) localCurId else queueCur.ifBlank { null }

    // Compact room header (F9): gradient card with QR + code + share.
    // One row, everything a friend needs: scan it, or type the code.
    val qr = remember(code) { qrBitmap("cresca://jam/$code") }
    Card(
        colors = CardDefaults.cardColors(containerColor = Color.Transparent),
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp)
            .background(
                Brush.horizontalGradient(
                    listOf(
                        MaterialTheme.colorScheme.primary,
                        MaterialTheme.colorScheme.primary.copy(alpha = 0.55f)
                    )
                ),
                RoundedCornerShape(20.dp)
            )
    ) {
        Row(
            Modifier.fillMaxWidth().padding(14.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (qr != null) {
                Image(
                    bitmap = qr.asImageBitmap(),
                    contentDescription = "Scan to join the JAM",
                    modifier = Modifier.size(84.dp).clip(RoundedCornerShape(12.dp))
                )
            }
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.Start) {
                Text(
                    "CODE",
                    style = MaterialTheme.typography.labelSmall,
                    color = Color.White.copy(alpha = 0.75f)
                )
                Text(
                    code.ifBlank { "···" },
                    style = MaterialTheme.typography.headlineSmall.copy(
                        fontWeight = FontWeight.Bold,
                        letterSpacing = androidx.compose.ui.unit.TextUnit.Unspecified
                    ),
                    color = Color.White,
                    maxLines = 1
                )
                Text(
                    (if (isHost) "You're hosting" else "You're in the JAM") +
                        if (members.isNotEmpty()) " • ${members.size}" else "",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.White.copy(alpha = 0.85f),
                    maxLines = 1
                )
            }
            IconButton(onClick = onShare) {
                Icon(
                    Icons.Filled.Share, contentDescription = "Share JAM",
                    tint = Color.White, modifier = Modifier.size(22.dp)
                )
            }
        }
    }

    // Members (first few + overflow count: a Row of 12 chips would overflow).
    if (members.isNotEmpty()) {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically
        ) {
            for (m in members.take(4)) {
                FilterChip(
                    selected = m.host,
                    onClick = {},
                    label = { Text((if (m.host) "♛ " else "") + m.name.take(12)) }
                )
            }
            if (members.size > 4) {
                Text(
                    "+${members.size - 4}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    } else {
        Text(
            "Waiting for friends…",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }

    if (isHost) {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                "Let guests control playback",
                style = MaterialTheme.typography.bodyMedium
            )
            Switch(checked = guestAllowed, onCheckedChange = onToggleGuests)
        }
    } else if (!canControl) {
        Text(
            "Host controls playback — you follow along. You can still add songs.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(vertical = 4.dp)
        )
    }

    if (!isHost && current != null) {
        OutlinedButton(
            onClick = onAddCurrent,
            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)
        ) {
            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("Add \"${current.title.take(28)}\" to the JAM")
        }
    }

    Text(
        "JAM queue (${shown.size}) — tap to play",
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 4.dp)
    )
    if (shown.isEmpty()) {
        Text(
            "Songs added to the queue show up here for everyone.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    } else {
        LazyColumn(Modifier.fillMaxWidth().height(220.dp)) {
            items(shown.take(60), key = { "jam-${it.first}" }) { row ->
                val isCur = row.first == curId
                Row(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        // Always tappable: denial toasts for control-less
                        // guests (F6), so no tap ever dies silently.
                        .clickable { onTapTrack(row.first) }
                        .padding(horizontal = 4.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    if (isCur) {
                        Box(
                            Modifier.size(8.dp).clip(CircleShape)
                                .background(MaterialTheme.colorScheme.primary)
                        )
                        Spacer(Modifier.width(8.dp))
                    } else {
                        Spacer(Modifier.width(16.dp))
                    }
                    Column(Modifier.weight(1f)) {
                        Text(
                            row.second, maxLines = 1,
                            style = MaterialTheme.typography.bodyMedium.copy(
                                fontWeight = if (isCur) FontWeight.Bold else FontWeight.Normal
                            ),
                            color = if (isCur) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurface
                        )
                        Text(
                            row.third, maxLines = 1,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }

    if (error != null) {
        Text(
            error,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 6.dp)
        )
    }

    Row(
        Modifier.fillMaxWidth().padding(top = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        OutlinedButton(onClick = onLeave, modifier = Modifier.weight(1f)) {
            Icon(Icons.Filled.ExitToApp, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("Leave")
        }
        if (isHost) {
            Button(
                onClick = onEnd,
                modifier = Modifier.weight(1f)
            ) {
                Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("End JAM")
            }
        }
    }
}

/** QR bitmap for a join link (zxing-core, one-shot, remembered by caller). */
private fun qrBitmap(text: String, size: Int = 512): android.graphics.Bitmap? {
    return try {
        if (text.isBlank()) return null
        val matrix = com.google.zxing.qrcode.QRCodeWriter().encode(
            text, com.google.zxing.BarcodeFormat.QR_CODE, size, size
        )
        val bmp = android.graphics.Bitmap.createBitmap(
            size, size, android.graphics.Bitmap.Config.RGB_565
        )
        for (x in 0 until size) {
            for (y in 0 until size) {
                bmp.setPixel(
                    x, y,
                    if (matrix.get(x, y)) android.graphics.Color.BLACK
                    else android.graphics.Color.WHITE
                )
            }
        }
        bmp
    } catch (e: Exception) {
        null
    }
}
