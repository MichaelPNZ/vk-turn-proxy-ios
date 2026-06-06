package com.vkturnproxy.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class DiagnosticsEvent(
    val name: String,
    val timestampEpochSeconds: Long,
    val sessionId: String,
    val profileId: ProfileId? = null,
    val severity: Severity = Severity.Info,
    val attributes: Map<String, String> = emptyMap(),
)

@Serializable
enum class Severity {
    Debug,
    Info,
    Warn,
    Error,
}

@Serializable
data class ServerHealthSnapshot(
    val healthy: Boolean,
    val serverVersion: String? = null,
    val protocolVersion: Int? = null,
    val activeSessions: Int? = null,
    val uptimeSeconds: Long? = null,
    val message: String? = null,
)
