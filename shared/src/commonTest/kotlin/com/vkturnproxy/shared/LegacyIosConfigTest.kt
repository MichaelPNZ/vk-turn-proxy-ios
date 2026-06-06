package com.vkturnproxy.shared

import com.vkturnproxy.shared.codec.LegacyIosConfig
import com.vkturnproxy.shared.model.ProfileId
import com.vkturnproxy.shared.model.TransportMode
import com.vkturnproxy.shared.validation.IosImportValidator
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LegacyIosConfigTest {
    @Test
    fun mapsFullBackupToSharedProfile() {
        val profile = LegacyIosConfig.profileFromFullBackup(
            rawJson = fullBackupJson,
            id = ProfileId("ios-full"),
            name = "iOS Full",
        )

        assertEquals("142.252.220.91:443", profile.proxy.peerAddr)
        assertEquals("https://vk.com/call/join/testLink123", profile.proxy.vkLink)
        assertEquals(30, profile.proxy.numConns)
        assertEquals(TransportMode.SrtpTurn, profile.proxy.mode)
        assertEquals("192.168.102.3/24", profile.wireGuard.interfaceAddress)
        assertTrue(profile.wireGuard.raw.contains("PrivateKey = private"))
    }

    @Test
    fun mapsConnectionLinkUrlToSharedProfile() {
        val url = "vkturnproxy://import?data=${connectionLinkJson.toBase64Url()}"

        val profile = LegacyIosConfig.profileFromConnectionLinkString(
            raw = url,
            id = ProfileId("ios-link"),
            name = "iOS Link",
        )

        assertEquals("142.252.220.91:443", profile.proxy.peerAddr)
        assertEquals(TransportMode.WrapA, profile.proxy.mode)
        assertEquals("secret", profile.proxy.wrapAPassword)
        assertEquals(12, profile.proxy.numConns)
        assertEquals("1.1.1.1", profile.wireGuard.dns.single())
    }

    @Test
    fun connectionLinkWithoutNumConnectionsUsesStabilityDefault() {
        val profile = LegacyIosConfig.profileFromConnectionLinkJson(
            rawJson = connectionLinkWithoutNumConnectionsJson,
            id = ProfileId("ios-link-default-conns"),
            name = "iOS Link Default Conns",
        )

        assertEquals(10, profile.proxy.numConns)
    }

    @Test
    fun validatesFullBackupForIosImport() {
        assertEquals(null, IosImportValidator.validateFullBackup(fullBackupJson))
    }

    @Test
    fun acceptsVkRuCallLinks() {
        val vkRuBackup = fullBackupJson.replace("https://vk.com/call/join/testLink123", "https://vk.ru/call/join/testLink123")

        assertEquals(null, IosImportValidator.validateFullBackup(vkRuBackup))
    }

    @OptIn(ExperimentalEncodingApi::class)
    private fun String.toBase64Url(): String =
        Base64.Default.encode(encodeToByteArray())
            .trimEnd('=')
            .replace('+', '-')
            .replace('/', '_')

    private val fullBackupJson = """
        {
          "version": 1,
          "type": "full",
          "exported_at": 1780690000,
          "settings": {
            "privateKey": "private",
            "peerPublicKey": "public",
            "presharedKey": "",
            "tunnelAddress": "192.168.102.3/24",
            "dnsServers": "1.1.1.1,8.8.8.8",
            "allowedIPs": "0.0.0.0/0",
            "vkLink": "https://vk.com/call/join/testLink123",
            "peerAddress": "142.252.220.91:443",
            "useDTLS": true,
            "numConnections": 30,
            "credPoolCooldownSeconds": 150,
            "useSrtp": true,
            "useUDP": false,
            "useWrapA": false
          }
        }
    """.trimIndent()

    private val connectionLinkJson = """
        {
          "version": 1,
          "type": "connection",
          "settings": {
            "vkLink": "https://vk.com/call/join/testLink123",
            "peerAddress": "142.252.220.91:443",
            "useWrapA": true,
            "wrapAPassword": "secret",
            "dnsServers": "1.1.1.1",
            "numConnections": 12
          }
        }
    """.trimIndent()

    private val connectionLinkWithoutNumConnectionsJson = """
        {
          "version": 1,
          "type": "connection",
          "settings": {
            "vkLink": "https://vk.com/call/join/testLink123",
            "peerAddress": "142.252.220.91:443",
            "useWrapA": true,
            "wrapAPassword": "secret",
            "dnsServers": "1.1.1.1"
          }
        }
    """.trimIndent()
}
