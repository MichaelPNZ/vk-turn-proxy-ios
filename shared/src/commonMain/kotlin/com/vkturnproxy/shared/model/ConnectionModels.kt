package com.vkturnproxy.shared.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class ConnectionStatus(
    val phase: ConnectionPhase = ConnectionPhase.Disconnected,
    val activeConns: Int = 0,
    val requestedConns: Int = 0,
    val lastError: String? = null,
    val captcha: CaptchaChallenge? = null,
    val diagnostics: DiagnosticsSummary = DiagnosticsSummary(),
) {
    val degraded: Boolean
        get() = phase == ConnectionPhase.Connected &&
            requestedConns > 0 &&
            activeConns in 0 until requestedConns
}

@Serializable
enum class ConnectionPhase {
    @SerialName("disconnected")
    Disconnected,

    @SerialName("connecting")
    Connecting,

    @SerialName("captcha")
    Captcha,

    @SerialName("connected")
    Connected,

    @SerialName("degraded")
    Degraded,

    @SerialName("disconnecting")
    Disconnecting,

    @SerialName("error")
    Error,
}

@Serializable
data class CaptchaChallenge(
    val sid: String,
    val imageUrl: String,
    val createdAtEpochSeconds: Long,
)

@Serializable
data class DiagnosticsSummary(
    val txBytes: Long = 0,
    val rxBytes: Long = 0,
    val reconnects: Long = 0,
    val turnRttMs: Double = 0.0,
    val lastHandshakeSec: Long = 0,
    val credPoolFilled: Int = 0,
    val credPoolWithCreds: Int = 0,
    val credPoolSize: Int = 0,
    val vkLastFetchError: String? = null,
    val vkLastFetchErrorAt: Long = 0,
)
