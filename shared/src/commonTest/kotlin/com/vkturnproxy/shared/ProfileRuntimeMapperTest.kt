package com.vkturnproxy.shared

import com.vkturnproxy.shared.model.Profile
import com.vkturnproxy.shared.model.ProfileId
import com.vkturnproxy.shared.model.ProxyConfig
import com.vkturnproxy.shared.model.TransportMode
import com.vkturnproxy.shared.model.WireGuardConfig
import com.vkturnproxy.shared.runtime.ProfileRuntimeMapper
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ProfileRuntimeMapperTest {
    @Test
    fun buildsWireGuardUapiAndProxyJson() {
        val profile = profile(
            mode = TransportMode.SrtpTurn,
            raw = """
                [Interface]
                PrivateKey = ${key(1)}
                Address = 10.77.77.3/32

                [Peer]
                PublicKey = ${key(2)}
                PresharedKey = ${key(3)}
                AllowedIPs = 0.0.0.0/0
            """.trimIndent(),
        )

        val payload = ProfileRuntimeMapper.toRuntimePayload(profile)

        assertTrue(payload.wireGuardUapi.contains("private_key=${hex(1)}"))
        assertTrue(payload.wireGuardUapi.contains("public_key=${hex(2)}"))
        assertTrue(payload.wireGuardUapi.contains("preshared_key=${hex(3)}"))
        assertTrue(payload.wireGuardUapi.contains("endpoint=142.252.220.91:56004"))
        assertTrue(payload.wireGuardUapi.contains("allowed_ip=0.0.0.0/0"))
        assertEquals("10.77.77.3/32", payload.interfaceAddress)
        assertEquals(listOf("1.1.1.1"), payload.dnsServers)
        assertEquals(listOf("0.0.0.0/0"), payload.allowedIps)
        assertTrue(payload.proxyJson.contains(""""peer_addr":"142.252.220.91:56004""""))
        assertTrue(payload.proxyJson.contains(""""use_srtp":true"""))
    }

    @Test
    fun wrapAModeDoesNotBuildWireGuardUapi() {
        val payload = ProfileRuntimeMapper.toRuntimePayload(
            profile(
                mode = TransportMode.WrapA,
                raw = "",
            ),
        )

        assertEquals("", payload.wireGuardUapi)
        assertTrue(payload.proxyJson.contains(""""use_wrap_a":true"""))
    }

    @OptIn(ExperimentalEncodingApi::class)
    private fun key(seed: Int): String =
        Base64.Default.encode(ByteArray(32) { index -> (seed + index).toByte() })

    private fun hex(seed: Int): String =
        ByteArray(32) { index -> (seed + index).toByte() }
            .joinToString(separator = "") { byte -> (byte.toInt() and 0xff).toString(16).padStart(2, '0') }

    private fun profile(
        mode: TransportMode,
        raw: String,
    ): Profile = Profile(
        id = ProfileId("runtime"),
        name = "Runtime",
        wireGuard = WireGuardConfig(
            raw = raw,
            interfaceAddress = "10.77.77.3/32",
            dns = listOf("1.1.1.1"),
            allowedIps = listOf("0.0.0.0/0"),
        ),
        proxy = ProxyConfig(
            peerAddr = "142.252.220.91:56004",
            vkLink = "https://vk.com/call/join/testLink123",
            numConns = 10,
            useDtls = true,
            useUdp = false,
            mode = mode,
            wrapAPassword = if (mode == TransportMode.WrapA) "secret" else null,
        ),
    )
}
