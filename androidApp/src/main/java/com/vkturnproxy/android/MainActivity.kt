package com.vkturnproxy.android

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.widget.Toast
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.text.selection.SelectionContainer
import com.vkturnproxy.shared.model.Profile
import com.vkturnproxy.shared.model.ProfileId
import com.vkturnproxy.shared.validation.IosImportValidator
import java.time.Instant

class MainActivity : ComponentActivity() {
    private lateinit var vpnPermissionLauncher: ActivityResultLauncher<Intent>
    private lateinit var stateHolder: AndroidAppStateHolder

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        stateHolder = AndroidAppStateHolder(
            context = this,
            requestVpnPermission = { intent -> vpnPermissionLauncher.launch(intent) },
        )
        vpnPermissionLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            stateHolder.onVpnPermissionResult(result.resultCode == Activity.RESULT_OK)
        }
        setContent {
            val vpnStatus by AndroidVpnRuntime.status.collectAsState()
            val diagnostics by AndroidVpnRuntime.diagnostics.collectAsState()
            AndroidApp(
                state = stateHolder.state,
                vpnStatus = vpnStatus,
                diagnosticsText = AndroidVpnRuntime.formatDiagnostics(diagnostics),
                onInputChanged = stateHolder::onInputChanged,
                onValidate = stateHolder::validateImport,
                onStartVpn = stateHolder::startVpn,
                onStopVpn = stateHolder::stopVpn,
                onCopyDiagnostics = stateHolder::copyDiagnostics,
                onShareDiagnostics = stateHolder::shareDiagnostics,
                onClearDiagnostics = stateHolder::clearDiagnostics,
            )
        }
        handleImportIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleImportIntent(intent)
    }

    private fun handleImportIntent(intent: Intent?) {
        val importText = intent?.dataString
            ?.takeIf { it.startsWith("vkturnproxy://import", ignoreCase = true) }
            ?: intent?.getStringExtra(EXTRA_IMPORT_TEXT)
        if (!importText.isNullOrBlank()) {
            stateHolder.importExternal(importText)
        }
    }

    companion object {
        const val EXTRA_IMPORT_TEXT = "com.vkturnproxy.android.extra.IMPORT_TEXT"
    }
}

private class AndroidAppStateHolder(
    private val context: Context,
    private val requestVpnPermission: (Intent) -> Unit,
) {
    var state by mutableStateOf(AndroidAppState())
        private set

    fun onInputChanged(value: String) {
        state = state.copy(importText = value, validationMessage = null, profilePayload = null)
    }

    fun importExternal(value: String) {
        AndroidVpnRuntime.log("profile_import_received", "External import intent received.")
        state = state.copy(importText = value, validationMessage = null, profilePayload = null)
        validateImport()
    }

    fun validateImport() {
        val input = state.importText.trim()
        if (input.isEmpty()) {
            state = state.copy(
                validationMessage = "Paste a full backup JSON or vkturnproxy:// import link.",
                validationOk = false,
                profilePayload = null,
            )
            return
        }
        runCatching { parseImportedProfile(input) }
            .onSuccess { profile ->
                AndroidVpnRuntime.log("profile_valid", "Profile validated for peer ${profile.proxy.peerAddr}.")
                state = state.copy(
                    validationMessage = "Profile payload is valid.",
                    validationOk = true,
                    profilePayload = profile.toVpnProfilePayload(),
                )
            }
            .onFailure { error ->
                AndroidVpnRuntime.log("profile_invalid", error.message ?: "Profile payload is invalid.")
                state = state.copy(
                    validationMessage = error.message ?: "Profile payload is invalid.",
                    validationOk = false,
                    profilePayload = null,
                )
            }
    }

    fun startVpn() {
        AndroidVpnRuntime.log("vpn_start_requested", "Start VPN requested from Android UI.")
        if (state.importText.isNotBlank() && state.profilePayload == null) {
            validateImport()
            if (state.profilePayload == null) return
        }
        val permissionIntent = VpnService.prepare(context)
        if (permissionIntent != null) {
            AndroidVpnRuntime.update(AndroidVpnStatus.PermissionRequired)
            requestVpnPermission(permissionIntent)
            return
        }
        startVpnService()
    }

    fun onVpnPermissionResult(granted: Boolean) {
        if (granted) {
            startVpnService()
        } else {
            AndroidVpnRuntime.update(AndroidVpnStatus.Error("Android VPN permission denied."))
        }
    }

    fun stopVpn() {
        AndroidVpnRuntime.log("vpn_stop_requested", "Stop VPN requested from Android UI.")
        context.startService(
            Intent(context, AndroidVpnService::class.java)
                .setAction(AndroidVpnService.ACTION_STOP),
        )
    }

    private fun startVpnService() {
        AndroidVpnRuntime.update(AndroidVpnStatus.Starting)
        val intent = Intent(context, AndroidVpnService::class.java)
            .setAction(AndroidVpnService.ACTION_START)
        state.profilePayload?.putInto(intent)
        context.startService(
            intent,
        )
    }

    fun copyDiagnostics() {
        val text = AndroidVpnRuntime.formatDiagnostics()
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("VK Turn Proxy diagnostics", text))
        Toast.makeText(context, "Diagnostics copied.", Toast.LENGTH_SHORT).show()
    }

    fun shareDiagnostics() {
        val text = AndroidVpnRuntime.formatDiagnostics()
        val intent = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_SUBJECT, "VK Turn Proxy Android diagnostics")
            .putExtra(Intent.EXTRA_TEXT, text)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(Intent.createChooser(intent, "Share diagnostics").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun clearDiagnostics() {
        AndroidVpnRuntime.clearDiagnostics()
        Toast.makeText(context, "Diagnostics cleared.", Toast.LENGTH_SHORT).show()
    }

    private fun parseImportedProfile(input: String): Profile {
        val id = ProfileId("android-import")
        return parseImportedProfile(input, id, "Imported profile")
    }
}

@Immutable
data class AndroidAppState(
    val importText: String = "",
    val validationMessage: String? = null,
    val validationOk: Boolean = false,
    val profilePayload: VpnProfilePayload? = null,
)

@Immutable
data class VpnProfilePayload(
    val wireGuardConfig: String,
    val interfaceAddress: String,
    val dnsServers: List<String>,
    val allowedIps: List<String>,
    val proxyConfig: String,
) {
    fun putInto(intent: Intent) {
        intent.putExtra(AndroidVpnService.EXTRA_WG_CONFIG, wireGuardConfig)
        intent.putExtra(AndroidVpnService.EXTRA_INTERFACE_ADDRESS, interfaceAddress)
        intent.putExtra(AndroidVpnService.EXTRA_DNS_SERVERS, dnsServers.toTypedArray())
        intent.putExtra(AndroidVpnService.EXTRA_ALLOWED_IPS, allowedIps.toTypedArray())
        intent.putExtra(AndroidVpnService.EXTRA_PROXY_CONFIG, proxyConfig)
    }
}

@Composable
fun AndroidApp(
    state: AndroidAppState,
    vpnStatus: AndroidVpnStatus,
    diagnosticsText: String,
    onInputChanged: (String) -> Unit,
    onValidate: () -> Unit,
    onStartVpn: () -> Unit,
    onStopVpn: () -> Unit,
    onCopyDiagnostics: () -> Unit,
    onShareDiagnostics: () -> Unit,
    onClearDiagnostics: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(AppColors.Background)
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Header()
        StatusPanel(
            vpnStatus = vpnStatus,
            onStartVpn = onStartVpn,
            onStopVpn = onStopVpn,
        )
        ImportPanel(
            text = state.importText,
            validationMessage = state.validationMessage,
            validationOk = state.validationOk,
            onInputChanged = onInputChanged,
            onValidate = onValidate,
        )
        DiagnosticsPanel(
            diagnosticsText = diagnosticsText,
            onCopyDiagnostics = onCopyDiagnostics,
            onShareDiagnostics = onShareDiagnostics,
            onClearDiagnostics = onClearDiagnostics,
        )
    }
}

@Composable
private fun Header() {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        AppText(
            text = "VK Turn Proxy",
            color = AppColors.TextPrimary,
            fontSize = 28.sp,
            fontWeight = FontWeight.SemiBold,
        )
        AppText(
            text = "Android MVP shell",
            color = AppColors.TextSecondary,
            fontSize = 15.sp,
        )
    }
}

@Composable
private fun StatusPanel(
    vpnStatus: AndroidVpnStatus,
    onStartVpn: () -> Unit,
    onStopVpn: () -> Unit,
) {
    Panel {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                AppText("Transport", color = AppColors.TextSecondary, fontSize = 13.sp)
                AppText(vpnStatus.label, color = AppColors.TextPrimary, fontSize = 18.sp, fontWeight = FontWeight.Medium)
            }
            val pillBg = if (vpnStatus.running) AppColors.SuccessBg else AppColors.WarningBg
            val pillFg = if (vpnStatus.running) AppColors.SuccessText else AppColors.WarningText
            StatusPill(if (vpnStatus.running) "TUN" else "MVP", pillBg, pillFg)
        }
        Spacer(Modifier.height(14.dp))
        AppText(
            text = vpnStatus.detail,
            color = AppColors.TextSecondary,
            fontSize = 14.sp,
        )
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PrimaryButton(text = "Start VPN", onClick = onStartVpn)
            SecondaryButton(text = "Stop", onClick = onStopVpn)
        }
    }
}

@Composable
private fun ImportPanel(
    text: String,
    validationMessage: String?,
    validationOk: Boolean,
    onInputChanged: (String) -> Unit,
    onValidate: () -> Unit,
) {
    Panel {
        AppText(
            text = "Import profile",
            color = AppColors.TextPrimary,
            fontSize = 18.sp,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.height(12.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(180.dp)
                .background(AppColors.InputBg, RoundedCornerShape(8.dp))
                .border(BorderStroke(1.dp, AppColors.Border), RoundedCornerShape(8.dp))
                .padding(12.dp),
        ) {
            BasicTextField(
                value = text,
                onValueChange = onInputChanged,
                modifier = Modifier.fillMaxSize(),
                textStyle = TextStyle(color = AppColors.TextPrimary, fontSize = 14.sp),
                cursorBrush = SolidColor(AppColors.Accent),
            )
            if (text.isEmpty()) {
                AppText(
                    text = "Paste full backup JSON or vkturnproxy:// link",
                    color = AppColors.TextMuted,
                    fontSize = 14.sp,
                )
            }
        }
        Spacer(Modifier.height(12.dp))
        PrimaryButton(text = "Validate", onClick = onValidate)
        validationMessage?.let { message ->
            Spacer(Modifier.height(12.dp))
            ValidationMessage(message = message, ok = validationOk)
        }
    }
}

@Composable
private fun DiagnosticsPanel(
    diagnosticsText: String,
    onCopyDiagnostics: () -> Unit,
    onShareDiagnostics: () -> Unit,
    onClearDiagnostics: () -> Unit,
) {
    Panel {
        AppText(
            text = "Diagnostics",
            color = AppColors.TextPrimary,
            fontSize = 18.sp,
            fontWeight = FontWeight.Medium,
        )
        Spacer(Modifier.height(12.dp))
        SelectionContainer {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(160.dp)
                    .background(AppColors.InputBg, RoundedCornerShape(8.dp))
                    .border(BorderStroke(1.dp, AppColors.Border), RoundedCornerShape(8.dp))
                    .padding(12.dp),
            ) {
                AppText(
                    text = diagnosticsText.ifBlank { "No diagnostics yet." },
                    color = AppColors.TextSecondary,
                    fontSize = 12.sp,
                )
            }
        }
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SecondaryButton(text = "Copy", onClick = onCopyDiagnostics)
            SecondaryButton(text = "Share", onClick = onShareDiagnostics)
            SecondaryButton(text = "Clear", onClick = onClearDiagnostics)
        }
    }
}

@Composable
private fun ValidationMessage(message: String, ok: Boolean) {
    val bg = if (ok) AppColors.SuccessBg else AppColors.ErrorBg
    val fg = if (ok) AppColors.SuccessText else AppColors.ErrorText
    SelectionContainer {
        AppText(
            text = message,
            color = fg,
            fontSize = 14.sp,
            modifier = Modifier
                .fillMaxWidth()
                .background(bg, RoundedCornerShape(8.dp))
                .padding(12.dp),
        )
    }
}

@Composable
private fun Panel(content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(AppColors.Surface, RoundedCornerShape(8.dp))
            .border(BorderStroke(1.dp, AppColors.Border), RoundedCornerShape(8.dp))
            .padding(16.dp),
        content = content,
    )
}

@Composable
private fun PrimaryButton(text: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .height(44.dp)
            .background(AppColors.Accent, RoundedCornerShape(8.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 18.dp),
        contentAlignment = Alignment.Center,
    ) {
        AppText(text = text, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun SecondaryButton(text: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .height(44.dp)
            .border(BorderStroke(1.dp, AppColors.Border), RoundedCornerShape(8.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 18.dp),
        contentAlignment = Alignment.Center,
    ) {
        AppText(text = text, color = AppColors.TextPrimary, fontSize = 15.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun StatusPill(text: String, bg: Color, fg: Color) {
    Row(
        modifier = Modifier
            .background(bg, RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).background(fg, RoundedCornerShape(8.dp)))
        Spacer(Modifier.width(6.dp))
        AppText(text = text, color = fg, fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun AppText(
    text: String,
    color: Color,
    fontSize: androidx.compose.ui.unit.TextUnit,
    modifier: Modifier = Modifier,
    fontWeight: FontWeight? = null,
) {
    BasicText(
        text = text,
        modifier = modifier,
        style = TextStyle(
            color = color,
            fontSize = fontSize,
            fontWeight = fontWeight,
        ),
    )
}

private object AppColors {
    val Background = Color(0xFFF7F8FA)
    val Surface = Color.White
    val InputBg = Color(0xFFF3F5F8)
    val Border = Color(0xFFD9DEE7)
    val TextPrimary = Color(0xFF172033)
    val TextSecondary = Color(0xFF5B6472)
    val TextMuted = Color(0xFF8B93A1)
    val Accent = Color(0xFF2563EB)
    val SuccessBg = Color(0xFFE8F6EE)
    val SuccessText = Color(0xFF166534)
    val ErrorBg = Color(0xFFFFECEB)
    val ErrorText = Color(0xFFB42318)
    val WarningBg = Color(0xFFFFF4DA)
    val WarningText = Color(0xFF8A5B00)
}

@Preview(showBackground = true, widthDp = 390)
@Composable
private fun AndroidAppPreview() {
    AndroidApp(
        state = AndroidAppState(validationMessage = "Profile payload is valid.", validationOk = true),
        vpnStatus = AndroidVpnStatus.Stopped,
        diagnosticsText = "2026-06-06T10:00:00Z status: Not connected",
        onInputChanged = {},
        onValidate = {},
        onStartVpn = {},
        onStopVpn = {},
        onCopyDiagnostics = {},
        onShareDiagnostics = {},
        onClearDiagnostics = {},
    )
}
