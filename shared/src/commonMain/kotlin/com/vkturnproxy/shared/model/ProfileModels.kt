package com.vkturnproxy.shared.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlin.jvm.JvmInline

const val CURRENT_PROFILE_SCHEMA_VERSION = 1
const val DEFAULT_PROXY_NUM_CONNS = 10

@Serializable
@JvmInline
value class ProfileId(val value: String)

@Serializable
data class Profile(
    val id: ProfileId,
    val name: String,
    val schemaVersion: Int = CURRENT_PROFILE_SCHEMA_VERSION,
    val wireGuard: WireGuardConfig,
    val proxy: ProxyConfig,
    val createdAtEpochSeconds: Long = 0,
    val updatedAtEpochSeconds: Long = 0,
)

@Serializable
data class WireGuardConfig(
    val raw: String,
    val interfaceAddress: String? = null,
    val dns: List<String> = emptyList(),
    val peerPublicKey: String? = null,
    val endpoint: String? = null,
    val allowedIps: List<String> = emptyList(),
)

@Serializable
data class ProxyConfig(
    @SerialName("peer_addr")
    val peerAddr: String,
    @SerialName("vk_link")
    val vkLink: String,
    @SerialName("num_conns")
    val numConns: Int = DEFAULT_PROXY_NUM_CONNS,
    @SerialName("use_dtls")
    val useDtls: Boolean = true,
    @SerialName("use_udp")
    val useUdp: Boolean = false,
    @SerialName("turn_server")
    val turnServer: String? = null,
    @SerialName("turn_port")
    val turnPort: String? = null,
    @SerialName("wrap_a_password")
    val wrapAPassword: String? = null,
    @SerialName("device_id")
    val deviceId: String? = null,
    val mode: TransportMode = TransportMode.SrtpTurn,
)

@Serializable
enum class TransportMode {
    @SerialName("dtls_turn")
    DtlsTurn,

    @SerialName("srtp_turn")
    SrtpTurn,

    @SerialName("wrap_a")
    WrapA,
}
