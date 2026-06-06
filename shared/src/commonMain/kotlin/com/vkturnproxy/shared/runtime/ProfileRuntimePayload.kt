package com.vkturnproxy.shared.runtime

import com.vkturnproxy.shared.model.Profile
import com.vkturnproxy.shared.model.TransportMode
import com.vkturnproxy.shared.model.WireGuardConfig
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

data class ProfileRuntimePayload(
    val wireGuardUapi: String,
    val interfaceAddress: String,
    val dnsServers: List<String>,
    val allowedIps: List<String>,
    val proxyJson: String,
)

object ProfileRuntimeMapper {
    fun toRuntimePayload(profile: Profile): ProfileRuntimePayload = ProfileRuntimePayload(
        wireGuardUapi = profile.buildWireGuardUapi(),
        interfaceAddress = profile.wireGuard.interfaceAddress ?: DEFAULT_INTERFACE_ADDRESS,
        dnsServers = profile.wireGuard.dns.ifEmpty { DEFAULT_DNS },
        allowedIps = profile.wireGuard.allowedIps.ifEmpty { DEFAULT_ALLOWED_IPS },
        proxyJson = profile.buildProxyJson().toString(),
    )

    private fun Profile.buildWireGuardUapi(): String {
        if (proxy.mode == TransportMode.WrapA) {
            return ""
        }
        val privateKey = wireGuard.setting("PrivateKey")
        val peerPublicKey = wireGuard.peerPublicKey ?: wireGuard.setting("PublicKey")
        val presharedKey = wireGuard.setting("PresharedKey")
        val allowedIps = wireGuard.allowedIps.ifEmpty {
            wireGuard.setting("AllowedIPs")?.splitCsv() ?: emptyList()
        }

        val lines = mutableListOf<String>()
        lines += "private_key=${parseWireGuardKey(privateKey, "Private Key")}"
        lines += "replace_peers=true"
        lines += "public_key=${parseWireGuardKey(peerPublicKey, "Peer Public Key")}"
        lines += "endpoint=${proxy.peerAddr}"
        allowedIps.forEach { lines += "allowed_ip=$it" }
        if (!presharedKey.isNullOrBlank()) {
            lines += "preshared_key=${parseWireGuardKey(presharedKey, "Preshared Key")}"
        }
        return lines.joinToString(separator = "\n")
    }

    private fun Profile.buildProxyJson(): JsonObject = buildJsonObject {
        put("peer_addr", proxy.peerAddr)
        put("vk_link", proxy.vkLink)
        put("num_conns", proxy.numConns)
        put("use_dtls", proxy.useDtls)
        put("use_udp", proxy.useUdp)
        put("use_srtp", proxy.mode == TransportMode.SrtpTurn)
        put("use_wrap_a", proxy.mode == TransportMode.WrapA)
        proxy.turnServer?.let { put("turn_server", JsonPrimitive(it)) }
        proxy.turnPort?.let { put("turn_port", JsonPrimitive(it)) }
        proxy.wrapAPassword?.let { put("wrap_a_password", JsonPrimitive(it)) }
        proxy.deviceId?.let { put("device_id", JsonPrimitive(it)) }
    }

    private fun WireGuardConfig.setting(name: String): String? =
        raw.lineSequence()
            .map { it.trim() }
            .firstOrNull { line ->
                line.startsWith(name, ignoreCase = true) && line.substringAfter(name).trimStart().startsWith("=")
            }
            ?.substringAfter("=")
            ?.trim()

    @OptIn(ExperimentalEncodingApi::class)
    private fun parseWireGuardKey(input: String?, field: String): String {
        val normalized = input
            ?.trim()
            ?.replace("-", "+")
            ?.replace("_", "/")
            ?.withBase64Padding()
            ?: ""
        require(normalized.isNotBlank()) { "$field is empty." }
        val bytes = runCatching { Base64.Default.decode(normalized) }
            .getOrElse { error("$field is not valid Base64.") }
        require(bytes.size == WIREGUARD_KEY_BYTES) {
            "$field decoded to ${bytes.size} bytes, expected $WIREGUARD_KEY_BYTES."
        }
        return bytes.toHex()
    }

    private fun String.withBase64Padding(): String =
        this + "=".repeat((4 - length % 4) % 4)

    private fun ByteArray.toHex(): String {
        val hex = CharArray(size * 2)
        forEachIndexed { index, byte ->
            val value = byte.toInt() and 0xff
            hex[index * 2] = HEX_CHARS[value ushr 4]
            hex[index * 2 + 1] = HEX_CHARS[value and 0x0f]
        }
        return hex.concatToString()
    }

    private fun String.splitCsv(): List<String> =
        split(",")
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    private const val DEFAULT_INTERFACE_ADDRESS = "192.168.102.3/24"
    private val DEFAULT_DNS = listOf("1.1.1.1")
    private val DEFAULT_ALLOWED_IPS = listOf("0.0.0.0/0")
    private const val WIREGUARD_KEY_BYTES = 32
    private val HEX_CHARS = "0123456789abcdef".toCharArray()
}
