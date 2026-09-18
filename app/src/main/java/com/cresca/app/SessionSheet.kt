package com.cresca.app

import android.webkit.WebView
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.launch

// Bottom sheet for YouTube sign-in state.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionSheet(
    loggedIn: Boolean,
    onLoginDone: () -> Unit,
    onLogout: () -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var webViewRef by remember { mutableStateOf<WebView?>(null) }
    var capturing by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(20.dp)
        ) {
            if (!loggedIn) {
                Text(
                    text = "Sign in with your Google account — your session stays on this device",
                    style = MaterialTheme.typography.bodyMedium
                )
                Spacer(modifier = Modifier.height(12.dp))
                // Factory runs on the main thread, safe for WebView creation.
                AndroidView(
                    factory = { c ->
                        YtSessionManager.loginWebView(c, {}).also { webViewRef = it }
                    },
                    modifier = Modifier.fillMaxWidth().height(420.dp)
                )
                Spacer(modifier = Modifier.height(12.dp))
                Button(
                    onClick = {
                        if (!capturing) {
                            capturing = true
                            scope.launch {
                                try {
                                    YtSessionManager.capture(context)
                                } catch (e: Exception) {
                                } finally {
                                    capturing = false
                                    onLoginDone()
                                }
                            }
                        }
                    },
                    enabled = !capturing,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(if (capturing) "Saving..." else "Done")
                }
                TextButton(
                    onClick = onDismiss,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Cancel")
                }
            } else {
                Text(
                    text = "You are signed in on this device",
                    style = MaterialTheme.typography.bodyLarge
                )
                Spacer(modifier = Modifier.height(12.dp))
                Button(
                    onClick = onLogout,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Logout")
                }
            }
            Spacer(modifier = Modifier.height(24.dp))
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            try {
                webViewRef?.destroy()
            } catch (e: Exception) {
            }
            webViewRef = null
        }
    }
}
