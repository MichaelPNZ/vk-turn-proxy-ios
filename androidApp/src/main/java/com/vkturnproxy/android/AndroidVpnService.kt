package com.vkturnproxy.android

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import mobilebridge.Mobilebridge
import mobilebridge.SocketProtector
import java.time.Instant

class AndroidVpnService : VpnService() {
    private var tun: ParcelFileDescriptor? = null
    private var bridgeHandle: Int = -1
    private var bridgeThread: Thread? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopTunnel()
            ACTION_START -> startTunnel(intent)
        }
        return START_STICKY
    }

    override fun onRevoke() {
        stopTunnel()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    private fun startTunnel(intent: Intent) {
        if (tun != null) {
            AndroidVpnRuntime.update(AndroidVpnStatus.Running("Android VPN interface already active."))
            return
        }
        val wgConfig = intent.getStringExtra(EXTRA_WG_CONFIG)
        val proxyConfig = intent.getStringExtra(EXTRA_PROXY_CONFIG)
        val interfaceAddress = intent.getStringExtra(EXTRA_INTERFACE_ADDRESS)
        val dnsServers = intent.getStringArrayExtra(EXTRA_DNS_SERVERS)?.toList().orEmpty()
        val allowedIps = intent.getStringArrayExtra(EXTRA_ALLOWED_IPS)?.toList().orEmpty()
        runCatching {
            val builder = Builder()
                .setSession("VK Turn Proxy")
                .setMtu(1280)
            if (wgConfig.isNullOrBlank() || proxyConfig.isNullOrBlank() || interfaceAddress.isNullOrBlank()) {
                builder
                    .addAddress("10.88.0.2", 32)
                    .addRoute("10.255.255.255", 32)
            } else {
                builder.addCidrAddress(interfaceAddress)
                dnsServers.forEach { builder.addDnsServer(it) }
                allowedIps.forEach { builder.addCidrRoute(it) }
            }
            builder.establish()
        }.onSuccess { fd ->
            if (fd == null) {
                AndroidVpnRuntime.update(AndroidVpnStatus.Error("VPN permission was not granted."))
                stopSelf()
            } else {
                tun = fd
                if (wgConfig.isNullOrBlank() || proxyConfig.isNullOrBlank()) {
                    AndroidVpnRuntime.update(AndroidVpnStatus.Running("Android VPN interface opened; Go bridge pending."))
                } else {
                    startBridge(fd, wgConfig, proxyConfig)
                }
            }
        }.onFailure { error ->
            AndroidVpnRuntime.update(AndroidVpnStatus.Error(error.message ?: "Failed to start Android VPN service."))
            stopSelf()
        }
    }

    private fun startBridge(
        fd: ParcelFileDescriptor,
        wgConfig: String,
        proxyConfig: String,
    ) {
        AndroidVpnRuntime.update(AndroidVpnStatus.Running("Android VPN interface opened; starting Go bridge."))
        Mobilebridge.setSocketProtector(AndroidSocketProtector(this))
        bridgeThread = Thread {
            val handle = Mobilebridge.startBootstrap(proxyConfig)
            if (handle <= 0) {
                AndroidVpnRuntime.update(AndroidVpnStatus.Error("Go bridge bootstrap failed to start."))
                return@Thread
            }
            bridgeHandle = handle
            when (Mobilebridge.waitBootstrapReady(handle, BOOTSTRAP_TIMEOUT_MS)) {
                1 -> {
                    val attach = Mobilebridge.attachWireGuard(handle, wgConfig, fd.fd)
                    if (attach == 1) {
                        AndroidVpnRuntime.update(AndroidVpnStatus.Running("Go bridge attached; protected routes active."))
                    } else {
                        AndroidVpnRuntime.update(AndroidVpnStatus.Error("WireGuard attach failed with code $attach."))
                        Mobilebridge.turnOff(handle)
                        bridgeHandle = -1
                    }
                }
                0 -> AndroidVpnRuntime.update(AndroidVpnStatus.Error("Go bridge bootstrap timed out."))
                else -> AndroidVpnRuntime.update(AndroidVpnStatus.Error("Go bridge bootstrap failed."))
            }
        }.also { it.start() }
    }

    private fun stopTunnel() {
        val handle = bridgeHandle
        bridgeHandle = -1
        if (handle > 0) {
            Mobilebridge.turnOff(handle)
        }
        bridgeThread = null
        tun?.close()
        tun = null
        AndroidVpnRuntime.update(AndroidVpnStatus.Stopped)
        stopSelf()
    }

    companion object {
        const val ACTION_START = "com.vkturnproxy.android.action.START_VPN"
        const val ACTION_STOP = "com.vkturnproxy.android.action.STOP_VPN"
        const val EXTRA_WG_CONFIG = "com.vkturnproxy.android.extra.WG_CONFIG"
        const val EXTRA_INTERFACE_ADDRESS = "com.vkturnproxy.android.extra.INTERFACE_ADDRESS"
        const val EXTRA_DNS_SERVERS = "com.vkturnproxy.android.extra.DNS_SERVERS"
        const val EXTRA_ALLOWED_IPS = "com.vkturnproxy.android.extra.ALLOWED_IPS"
        const val EXTRA_PROXY_CONFIG = "com.vkturnproxy.android.extra.PROXY_CONFIG"
        private const val BOOTSTRAP_TIMEOUT_MS = 120_000
    }
}

private fun VpnService.Builder.addCidrAddress(cidr: String): VpnService.Builder {
    val (address, prefix) = parseCidr(cidr)
    return addAddress(address, prefix)
}

private fun VpnService.Builder.addCidrRoute(cidr: String): VpnService.Builder {
    val (address, prefix) = parseCidr(cidr)
    return addRoute(address, prefix)
}

private fun parseCidr(cidr: String): Pair<String, Int> {
    val address = cidr.substringBefore("/").trim()
    val prefix = cidr.substringAfter("/", missingDelimiterValue = "32").trim().toInt()
    require(address.isNotBlank()) { "Empty CIDR address: $cidr" }
    return address to prefix
}

private class AndroidSocketProtector(
    private val vpnService: VpnService,
) : SocketProtector {
    override fun protect(fd: Int): Boolean = vpnService.protect(fd)
}

sealed interface AndroidVpnStatus {
    val label: String
    val detail: String
    val running: Boolean

    data object Stopped : AndroidVpnStatus {
        override val label: String = "Not connected"
        override val detail: String = "Android VpnService is stopped."
        override val running: Boolean = false
    }

    data object PermissionRequired : AndroidVpnStatus {
        override val label: String = "Permission required"
        override val detail: String = "Approve Android VPN permission to open the local tunnel interface."
        override val running: Boolean = false
    }

    data object Starting : AndroidVpnStatus {
        override val label: String = "Starting"
        override val detail: String = "Opening Android VPN interface."
        override val running: Boolean = false
    }

    data class Running(override val detail: String) : AndroidVpnStatus {
        override val label: String = "Interface active"
        override val running: Boolean = true
    }

    data class Error(override val detail: String) : AndroidVpnStatus {
        override val label: String = "Error"
        override val running: Boolean = false
    }
}

object AndroidVpnRuntime {
    private val mutableStatus = MutableStateFlow<AndroidVpnStatus>(AndroidVpnStatus.Stopped)
    private val mutableDiagnostics = MutableStateFlow<List<AndroidDiagnosticEvent>>(emptyList())
    val status: StateFlow<AndroidVpnStatus> = mutableStatus.asStateFlow()
    val diagnostics: StateFlow<List<AndroidDiagnosticEvent>> = mutableDiagnostics.asStateFlow()

    @Synchronized
    fun update(status: AndroidVpnStatus) {
        mutableStatus.value = status
        appendDiagnostic("status", "${status.label}: ${status.detail}")
    }

    @Synchronized
    fun log(event: String, detail: String) {
        appendDiagnostic(event, detail)
    }

    @Synchronized
    fun clearDiagnostics() {
        mutableDiagnostics.value = emptyList()
    }

    fun formatDiagnostics(events: List<AndroidDiagnosticEvent> = mutableDiagnostics.value): String =
        events.joinToString(separator = "\n") { event ->
            "${Instant.ofEpochMilli(event.timestampMillis)} ${event.event}: ${event.detail}"
        }

    private fun appendDiagnostic(event: String, detail: String) {
        val next = mutableDiagnostics.value + AndroidDiagnosticEvent(
            timestampMillis = System.currentTimeMillis(),
            event = event,
            detail = detail,
        )
        mutableDiagnostics.value = next.takeLast(MAX_DIAGNOSTIC_EVENTS)
    }

    private const val MAX_DIAGNOSTIC_EVENTS = 200
}

data class AndroidDiagnosticEvent(
    val timestampMillis: Long,
    val event: String,
    val detail: String,
)
