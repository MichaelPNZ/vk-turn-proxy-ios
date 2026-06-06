package com.vkturnproxy.shared.codec

import com.vkturnproxy.shared.model.Profile
import com.vkturnproxy.shared.model.DEFAULT_PROXY_NUM_CONNS
import com.vkturnproxy.shared.model.ProfileId
import com.vkturnproxy.shared.model.ProxyConfig
import com.vkturnproxy.shared.model.TransportMode
import com.vkturnproxy.shared.model.WireGuardConfig
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

object LegacyIosConfig {
    fun profileFromFullBackup(
        rawJson: String,
        id: ProfileId,
        name: String,
    ): Profile {
        val backup = ProfileJson.json.decodeFromString<LegacyIosAppConfig>(rawJson)
        require(backup.version == 1) { "Unsupported iOS backup version ${backup.version}" }
        require(backup.type == "full") { "Expected full backup, got ${backup.type}" }
        return backup.settings.toProfile(id, name, backup.exportedAt)
    }

    fun profileFromConnectionLinkJson(
        rawJson: String,
        id: ProfileId,
        name: String,
    ): Profile {
        val link = ProfileJson.json.decodeFromString<LegacyIosConnectionLink>(rawJson)
        require(link.version == 1) { "Unsupported iOS connection link version ${link.version}" }
        require(link.type == "connection") { "Expected connection link, got ${link.type}" }
        return link.settings.toProfile(id, name, 0)
    }

    fun profileFromConnectionLinkString(
        raw: String,
        id: ProfileId,
        name: String,
    ): Profile {
        val trimmed = raw.trim()
        val payload = if (trimmed.startsWith("vkturnproxy:", ignoreCase = true)) {
            val query = trimmed.substringAfter("?", missingDelimiterValue = "")
            query.split("&")
                .firstOrNull { it.substringBefore("=") == "data" }
                ?.substringAfter("=")
                ?.percentDecode()
                ?: error("Connection link is missing data query parameter")
        } else {
            trimmed
        }
        return profileFromConnectionLinkJson(decodeBase64Url(payload), id, name)
    }

    @OptIn(ExperimentalEncodingApi::class)
    private fun decodeBase64Url(raw: String): String {
        val normalized = raw.replace('-', '+').replace('_', '/')
        val padded = normalized + "=".repeat((4 - normalized.length % 4) % 4)
        return Base64.Default.decode(padded).decodeToString()
    }

    private fun String.percentDecode(): String {
        val out = StringBuilder(length)
        var i = 0
        while (i < length) {
            val c = this[i]
            if (c == '%' && i + 2 < length) {
                val hex = substring(i + 1, i + 3)
                val value = hex.toIntOrNull(16)
                if (value != null) {
                    out.append(value.toChar())
                    i += 3
                    continue
                }
            }
            out.append(if (c == '+') ' ' else c)
            i++
        }
        return out.toString()
    }
}

@Serializable
data class LegacyIosAppConfig(
    val version: Int,
    val type: String,
    @SerialName("exported_at")
    val exportedAt: Long,
    val settings: LegacyIosAppSettings,
)

@Serializable
data class LegacyIosAppSettings(
    val privateKey: String = "",
    val peerPublicKey: String = "",
    val presharedKey: String = "",
    val tunnelAddress: String = "192.168.102.3/24",
    val dnsServers: String = "1.1.1.1",
    val allowedIPs: String = "0.0.0.0/0",
    val vkLink: String,
    val peerAddress: String,
    val useDTLS: Boolean = true,
    val numConnections: Int = DEFAULT_PROXY_NUM_CONNS,
    val useSrtp: Boolean? = null,
    val useUDP: Boolean? = null,
    val useWrapA: Boolean? = null,
    val wrapAPassword: String? = null,
)

@Serializable
data class LegacyIosConnectionLink(
    val version: Int,
    val type: String,
    val settings: LegacyIosConnectionSettings,
)

@Serializable
data class LegacyIosConnectionSettings(
    val privateKey: String? = null,
    val peerPublicKey: String? = null,
    val presharedKey: String? = null,
    val tunnelAddress: String? = null,
    val allowedIPs: String? = null,
    val vkLink: String,
    val peerAddress: String,
    val useDTLS: Boolean? = null,
    val useSrtp: Boolean? = null,
    val useUDP: Boolean? = null,
    val useWrapA: Boolean? = null,
    val wrapAPassword: String? = null,
    val dnsServers: String? = null,
    val numConnections: Int? = null,
)

private fun LegacyIosAppSettings.toProfile(
    id: ProfileId,
    name: String,
    exportedAt: Long,
): Profile = Profile(
    id = id,
    name = name,
    wireGuard = toWireGuardConfig(),
    proxy = toProxyConfig(),
    createdAtEpochSeconds = exportedAt,
    updatedAtEpochSeconds = exportedAt,
)

private fun LegacyIosConnectionSettings.toProfile(
    id: ProfileId,
    name: String,
    exportedAt: Long,
): Profile = Profile(
    id = id,
    name = name,
    wireGuard = WireGuardConfig(
        raw = buildWireGuardRaw(
            privateKey = privateKey.orEmpty(),
            peerPublicKey = peerPublicKey.orEmpty(),
            presharedKey = presharedKey.orEmpty(),
            tunnelAddress = tunnelAddress ?: "192.168.102.3/24",
            dnsServers = dnsServers ?: "1.1.1.1",
            allowedIPs = allowedIPs ?: "0.0.0.0/0",
            endpoint = peerAddress,
        ),
        interfaceAddress = tunnelAddress,
        dns = dnsServers?.splitCsv() ?: emptyList(),
        peerPublicKey = peerPublicKey,
        endpoint = peerAddress,
        allowedIps = allowedIPs?.splitCsv() ?: emptyList(),
    ),
    proxy = ProxyConfig(
        peerAddr = peerAddress,
        vkLink = vkLink,
        numConns = numConnections ?: DEFAULT_PROXY_NUM_CONNS,
        useDtls = useDTLS ?: true,
        useUdp = useUDP ?: false,
        wrapAPassword = wrapAPassword,
        mode = resolveMode(useSrtp = useSrtp, useWrapA = useWrapA),
    ),
    createdAtEpochSeconds = exportedAt,
    updatedAtEpochSeconds = exportedAt,
)

private fun LegacyIosAppSettings.toWireGuardConfig(): WireGuardConfig = WireGuardConfig(
    raw = buildWireGuardRaw(
        privateKey = privateKey,
        peerPublicKey = peerPublicKey,
        presharedKey = presharedKey,
        tunnelAddress = tunnelAddress,
        dnsServers = dnsServers,
        allowedIPs = allowedIPs,
        endpoint = peerAddress,
    ),
    interfaceAddress = tunnelAddress,
    dns = dnsServers.splitCsv(),
    peerPublicKey = peerPublicKey,
    endpoint = peerAddress,
    allowedIps = allowedIPs.splitCsv(),
)

private fun LegacyIosAppSettings.toProxyConfig(): ProxyConfig = ProxyConfig(
    peerAddr = peerAddress,
    vkLink = vkLink,
    numConns = numConnections,
    useDtls = useDTLS,
    useUdp = useUDP ?: false,
    wrapAPassword = wrapAPassword,
    mode = resolveMode(useSrtp = useSrtp, useWrapA = useWrapA),
)

private fun resolveMode(useSrtp: Boolean?, useWrapA: Boolean?): TransportMode = when {
    useWrapA == true -> TransportMode.WrapA
    useSrtp == true -> TransportMode.SrtpTurn
    else -> TransportMode.DtlsTurn
}

private fun buildWireGuardRaw(
    privateKey: String,
    peerPublicKey: String,
    presharedKey: String,
    tunnelAddress: String,
    dnsServers: String,
    allowedIPs: String,
    endpoint: String,
): String = buildString {
    appendLine("[Interface]")
    if (privateKey.isNotBlank()) appendLine("PrivateKey = $privateKey")
    appendLine("Address = $tunnelAddress")
    if (dnsServers.isNotBlank()) appendLine("DNS = $dnsServers")
    appendLine()
    appendLine("[Peer]")
    if (peerPublicKey.isNotBlank()) appendLine("PublicKey = $peerPublicKey")
    if (presharedKey.isNotBlank()) appendLine("PresharedKey = $presharedKey")
    appendLine("Endpoint = $endpoint")
    appendLine("AllowedIPs = $allowedIPs")
}.trim()

private fun String.splitCsv(): List<String> =
    split(",")
        .map { it.trim() }
        .filter { it.isNotEmpty() }
