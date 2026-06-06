package com.vkturnproxy.shared

import com.vkturnproxy.shared.codec.ProfileJson
import com.vkturnproxy.shared.model.Profile
import com.vkturnproxy.shared.model.ProfileId
import com.vkturnproxy.shared.model.ProxyConfig
import com.vkturnproxy.shared.model.WireGuardConfig
import com.vkturnproxy.shared.validation.ConfigValidator
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ConfigValidatorTest {
    @Test
    fun acceptsValidProfile() {
        val result = ConfigValidator.validateProfile(validProfile())

        assertTrue(result.isValid)
    }

    @Test
    fun rejectsInvalidPeerPortAndConnCount() {
        val result = ConfigValidator.validateProxyConfig(
            ProxyConfig(
                peerAddr = "142.252.220.91:90000",
                vkLink = "https://vk.com/call/join/testLink123",
                numConns = 0,
            ),
        )

        assertFalse(result.isValid)
        assertEquals(
            listOf("proxy.peerAddr", "proxy.numConns"),
            result.issues.map { it.field },
        )
    }

    @Test
    fun roundTripsProfileJson() {
        val profile = validProfile()

        val decoded = ProfileJson.decode(ProfileJson.encode(profile))

        assertEquals(profile, decoded)
    }

    private fun validProfile(): Profile = Profile(
        id = ProfileId("primary"),
        name = "Primary",
        wireGuard = WireGuardConfig(
            raw = """
                [Interface]
                PrivateKey = private
                Address = 10.0.0.2/32

                [Peer]
                PublicKey = public
                Endpoint = 142.252.220.91:51820
                AllowedIPs = 0.0.0.0/0
            """.trimIndent(),
            interfaceAddress = "10.0.0.2/32",
            peerPublicKey = "public",
            endpoint = "142.252.220.91:51820",
            allowedIps = listOf("0.0.0.0/0"),
        ),
        proxy = ProxyConfig(
            peerAddr = "142.252.220.91:443",
            vkLink = "https://vk.com/call/join/testLink123",
            numConns = 30,
        ),
    )
}
