package com.vkturnproxy.desktop.windows

import com.vkturnproxy.shared.model.Profile
import com.vkturnproxy.shared.model.ProfileId
import com.vkturnproxy.shared.model.ProxyConfig
import com.vkturnproxy.shared.model.TransportMode
import com.vkturnproxy.shared.model.WireGuardConfig
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import java.nio.file.Files
import java.nio.file.Path

class WindowsTunnelRuntimeTest {
    @Test
    fun buildsStartRequestFromSharedRuntimePayload() {
        val request = WindowsTunnelRuntime.prepareStartRequest(profile())
        val encoded = WindowsTunnelRuntime.encodeStartRequest(request)

        assertEquals("VKTurnProxyTunnel", request.serviceName)
        assertEquals("VK Turn Proxy", request.adapterName)
        assertEquals("142.252.220.91:56004", request.peerAddress)
        assertEquals("10.88.0.2/32", request.interfaceAddress)
        assertEquals(listOf("1.1.1.1"), request.dnsServers)
        assertEquals(listOf("0.0.0.0/0"), request.allowedIps)
        assertTrue(request.wireGuardUapi.contains("endpoint=142.252.220.91:56004"))
        assertTrue(request.proxyJson.contains(""""use_srtp":true"""))
        assertTrue(encoded.contains(""""schemaVersion": 1"""))
    }

    @Test
    fun preflightBlocksOutsideWindowsOrWithoutServiceExecutable() {
        val result = WindowsTunnelRuntime.preflight(osName = "Mac OS X")

        assertFalse(result.ready)
        assertTrue(result.blockers.any { it.contains("Windows host") })
        assertTrue(result.blockers.any { it.contains("service executable") })
        assertTrue(result.warnings.any { it.contains("EXE installer source exists") })
    }

    @Test
    fun serviceCommandsTargetRequestedExecutable() {
        val commands = WindowsTunnelRuntime.serviceInstallCommands(
            serviceExecutable = java.nio.file.Path.of("C:/Program Files/VKTurnProxy/vkturnproxy-tunnel-service.exe"),
        )

        assertTrue(commands.first().startsWith("sc.exe create VKTurnProxyTunnel"))
        assertTrue(commands.any { it.contains("vkturnproxy-tunnel-service.exe") })
        assertTrue(commands.any { it == "sc.exe start VKTurnProxyTunnel" })
        assertTrue(commands.any { it.contains("-mode control-start") })
        assertTrue(commands.any { it.contains("-mode control-status") })
        assertTrue(commands.any { it.contains("-mode control-logs") })
        assertTrue(commands.any { it.contains("-mode control-stop") })
    }

    @Test
    fun buildsServiceControlCommandArguments() {
        val exe = Path.of("C:/Program Files/VKTurnProxy/vk-turn-proxy-windows-service.exe")
        val request = Path.of("C:/ProgramData/VKTurnProxy/start-request.json")

        val start = WindowsTunnelRuntime.controlCommandArgs(exe, "start", request)
        val status = WindowsTunnelRuntime.controlCommandArgs(exe, "status")
        val stop = WindowsTunnelRuntime.controlCommandArgs(exe, "stop")
        val logs = WindowsTunnelRuntime.controlCommandArgs(exe, "logs")

        assertEquals(listOf(exe.toAbsolutePath().toString(), "-mode", "control-start", "-request", request.toAbsolutePath().toString()), start)
        assertEquals(listOf(exe.toAbsolutePath().toString(), "-mode", "control-status"), status)
        assertEquals(listOf(exe.toAbsolutePath().toString(), "-mode", "control-stop"), stop)
        assertEquals(listOf(exe.toAbsolutePath().toString(), "-mode", "control-logs"), logs)
    }

    @Test
    fun discoversPackagedServiceExecutableNearWorkingDirectory() {
        val root = Files.createTempDirectory("vkturnproxy-desktop")
        val exe = root.resolve("bin").resolve(WindowsTunnelRuntime.SERVICE_EXE_NAME)
        Files.createDirectories(exe.parent)
        Files.writeString(exe, "placeholder")

        assertEquals(exe, WindowsTunnelRuntime.discoverServiceExecutable(workingDir = root))
        assertNull(WindowsTunnelRuntime.discoverServiceExecutable(workingDir = Files.createTempDirectory("vkturnproxy-empty")))
    }

    @OptIn(ExperimentalEncodingApi::class)
    private fun key(seed: Int): String =
        Base64.Default.encode(ByteArray(32) { index -> (seed + index).toByte() })

    private fun profile(): Profile = Profile(
        id = ProfileId("windows-runtime"),
        name = "Windows Runtime",
        wireGuard = WireGuardConfig(
            raw = """
                [Interface]
                PrivateKey = ${key(1)}
                Address = 10.88.0.2/32

                [Peer]
                PublicKey = ${key(2)}
                AllowedIPs = 0.0.0.0/0
            """.trimIndent(),
            interfaceAddress = "10.88.0.2/32",
            dns = listOf("1.1.1.1"),
            allowedIps = listOf("0.0.0.0/0"),
        ),
        proxy = ProxyConfig(
            peerAddr = "142.252.220.91:56004",
            vkLink = "https://vk.com/call/join/windowsRuntimeTest",
            numConns = 8,
            useDtls = true,
            useUdp = false,
            mode = TransportMode.SrtpTurn,
        ),
    )
}
