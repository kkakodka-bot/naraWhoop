package com.noop.push

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.BuildConfig
import com.noop.ui.NoopButton
import com.noop.ui.NoopType
import com.noop.ui.ScreenScaffold
import kotlinx.coroutines.delay

/** Retrying this gate does not restart setup, erase history, or reset the strap. */
@Composable
fun DeviceLinkGate(): Boolean {
    if (BuildConfig.ENABLE_DEMO) return true
    val context = LocalContext.current
    var confirmed by remember { mutableStateOf(DeviceLinkStore.currentConfirmed(context)) }
    var attempt by remember { mutableIntStateOf(0) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var identity by remember { mutableStateOf(runCatching { DeviceLinkStore.identity(context) }.getOrNull()) }
    LaunchedEffect(Unit) {
        while (true) {
            identity = runCatching { DeviceLinkStore.identity(context) }.getOrNull()
            confirmed = DeviceLinkStore.currentConfirmed(context)
            delay(500)
        }
    }
    LaunchedEffect(identity, attempt) {
        if (identity == null || DeviceLinkStore.currentConfirmed(context)) return@LaunchedEffect
        working = true; error = null
        try {
            ServerScoreClient.registerCurrentDevice(context)
            confirmed = DeviceLinkStore.currentConfirmed(context)
        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (failure: Exception) {
            if (failure is ServerScoreClient.Unauthorized) {
                val manager = PushEnrollmentManager.from(context)
                manager.currentCredential()?.takeIf { it.uploadToken == failure.accessToken }?.let(manager::clearIfCurrent)
            }
            error = "Connect to the internet and retry. Your setup and pairing have been saved."
        }
        finally { working = false }
    }
    if (confirmed && DeviceLinkStore.currentConfirmed(context)) return true
    ScreenScaffold(title = "Linking your device", subtitle = "Waiting for your account to confirm this phone and device.") {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("An internet connection is required for this first confirmation. After it is saved, you can keep using the app offline.", style = NoopType.body)
            error?.let { Text(it, style = NoopType.body) }
            NoopButton(text = if (working) "Waiting for confirmation…" else "Retry", enabled = !working,
                fullWidth = true, onClick = { attempt++ })
        }
    }
    return false
}
