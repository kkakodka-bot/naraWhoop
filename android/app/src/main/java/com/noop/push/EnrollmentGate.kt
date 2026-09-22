package com.noop.push

import android.app.Activity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.noop.BuildConfig
import com.noop.ui.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Required for new installs and upgrades; independent of strap setup and never resets the strap. */
@Composable
fun EnrollmentGate(): Boolean {
    if (BuildConfig.ENABLE_DEMO) return true
    val context = LocalContext.current
    var manager by remember { mutableStateOf<PushEnrollmentManager?>(null) }
    var storageAvailable by remember { mutableStateOf(false) }
    var credential by remember { mutableStateOf<PushEnrollmentCredential?>(null) }
    var code by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var retiring by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) {
        while (true) {
            try {
                val current = manager ?: PushEnrollmentManager.from(context).also { manager = it }
                credential = current.currentCredential()
                retiring = current.retirementPending()
                storageAvailable = true
            } catch (_: Exception) { storageAvailable = false }
            delay(500)
        }
    }
    if (storageAvailable && credential != null && EnrollmentDataScope.active(context)) return true
    ScreenScaffold(title = "Connect your account", subtitle = "Use your personal enrollment code on each phone.") {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (!storageAvailable) {
                Text("Secure storage is temporarily unavailable. Unlock the phone and keep this screen open to retry.", style = NoopType.body)
            } else if (retiring) {
                Text("Retirement is pending. Collection is paused and previous records retain their original owner.", style = NoopType.body)
                InstallationRetirementControl(resume = true)
            } else if (PushEnrollmentManager.requiresRestart || credential != null) {
                Text(if (PushEnrollmentManager.requiresRestart)
                    "Installation retired. Close and reopen NARA before enrolling another person. Previous records remain with their original account."
                    else "Enrollment saved. Close and reopen NARA to start your account's data store. Your strap pairing is kept. Earlier unassigned history stays on this phone and is not uploaded.", style = NoopType.body)
                NoopButton(text = "Close app", fullWidth = true, onClick = {
                    (context as? Activity)?.finishAndRemoveTask()
                    android.os.Process.killProcess(android.os.Process.myPid())
                })
            } else {
                Text("Enter the code provided for you. A replacement or second phone needs a new code for the same account. This step does not erase or reset your strap.", style = NoopType.body)
                OutlinedTextField(value = code, onValueChange = { code = it }, singleLine = true,
                    enabled = !working, label = { Text("Enrollment code") },
                    visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                NoopButton(text = if (working) "Connecting…" else "Continue", fullWidth = true,
                    enabled = !working && code.isNotBlank() && manager != null, onClick = {
                        working = true
                        scope.launch {
                            try {
                                when (val result = manager?.enroll(code)) {
                                    is PushEnrollmentResult.Success -> { credential = result.credential; code = ""; message = null }
                                    is PushEnrollmentResult.Failure -> message = when (result.code) {
                                        PushEnrollmentFailureCode.IDENTITY_CONFLICT -> "This phone's retained data belongs to another account. Use a separate installation for a different person."
                                        PushEnrollmentFailureCode.NOT_CONFIGURED -> "This build is missing its cloud configuration. Contact your administrator."
                                        PushEnrollmentFailureCode.CODE_REJECTED, PushEnrollmentFailureCode.UNAUTHORIZED -> "This code could not be accepted. Request a fresh code for your account."
                                        else -> "Enrollment could not finish. Check your connection and try again."
                                    }
                                    null -> message = "Secure storage is unavailable. Close the app and try again."
                                }
                            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                                throw cancelled
                            } catch (_: Exception) {
                                message = "Enrollment could not be saved. Close the app and try again."
                            } finally { working = false }
                        }
                    })
                if (manager == null) Text("Secure storage is unavailable. Close the app and try again.", color = Palette.statusWarning)
                message?.let { Text(it, color = Palette.statusWarning) }
            }
        }
    }
    return false
}

@Composable
fun InstallationRetirementControl(resume: Boolean = false) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var confirm by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    NoopButton(text = if (busy) "Retiring…" else if (resume) "Retry retirement" else "Retire this installation",
        fullWidth = true, enabled = !busy, onClick = { confirm = true })
    error?.let { Text(it,color=Palette.statusWarning) }
    if (confirm) androidx.compose.material3.AlertDialog(onDismissRequest={ confirm=false },
        title={ Text("Retire this installation?") },
        text={ Text("Pending records stay with the original account. Reopen NARA before enrolling another person.") },
        confirmButton={ androidx.compose.material3.TextButton(onClick={
            confirm=false; busy=true
            scope.launch {
                try { PushEnrollmentManager.from(context).retireInstallation(); error=null }
                catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                catch (_: Exception) { error="Retirement is pending. Check your connection and retry." }
                finally { busy=false }
            }
        }) { Text("Retire installation") } },
        dismissButton={ androidx.compose.material3.TextButton(onClick={confirm=false}) {Text("Cancel")} })
}
