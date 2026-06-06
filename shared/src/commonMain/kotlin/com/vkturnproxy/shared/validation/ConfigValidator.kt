package com.vkturnproxy.shared.validation

import com.vkturnproxy.shared.model.CURRENT_PROFILE_SCHEMA_VERSION
import com.vkturnproxy.shared.model.Profile
import com.vkturnproxy.shared.model.ProxyConfig

object ConfigValidator {
    private val hostPortRegex = Regex("""^[A-Za-z0-9.-]+:[0-9]{1,5}$""")
    private val vkLinkIdRegex = Regex("""^[A-Za-z0-9_-]{6,}$""")

    fun validateProfile(profile: Profile): ValidationResult = buildList {
        if (profile.schemaVersion != CURRENT_PROFILE_SCHEMA_VERSION) {
            add(ValidationIssue("profile.schemaVersion", "Unsupported profile schema version"))
        }
        if (profile.id.value.isBlank()) {
            add(ValidationIssue("profile.id", "Profile id is required"))
        }
        if (profile.name.isBlank()) {
            add(ValidationIssue("profile.name", "Profile name is required"))
        }
        addAll(validateProxyConfig(profile.proxy).issues)
        if (profile.wireGuard.raw.isBlank()) {
            add(ValidationIssue("wireGuard.raw", "WireGuard config is required"))
        }
    }.toValidationResult()

    fun validateProxyConfig(config: ProxyConfig): ValidationResult = buildList {
        if (!config.peerAddr.isValidHostPort()) {
            add(ValidationIssue("proxy.peerAddr", "Peer address must be host:port"))
        }
        val port = config.peerAddr.substringAfterLast(':', "").toIntOrNull()
        if (port == null || port !in 1..65535) {
            add(ValidationIssue("proxy.peerAddr", "Peer port must be in 1..65535"))
        }
        if (!config.vkLink.isValidVkLink()) {
            add(ValidationIssue("proxy.vkLink", "VK link must be a vk.com call URL or link id"))
        }
        if (config.numConns !in 1..100) {
            add(ValidationIssue("proxy.numConns", "Connection count must be in 1..100"))
        }
        config.turnPort?.let { rawPort ->
            val turnPort = rawPort.toIntOrNull()
            if (turnPort == null || turnPort !in 1..65535) {
                add(ValidationIssue("proxy.turnPort", "TURN port must be in 1..65535"))
            }
        }
    }.toValidationResult()

    private fun String.isValidHostPort(): Boolean = hostPortRegex.matches(this)

    private fun String.isValidVkLink(): Boolean =
        startsWith("https://vk.com/call/join/") ||
            startsWith("https://vk.ru/call/join/") ||
            startsWith("vk.com/call/join/") ||
            startsWith("vk.ru/call/join/") ||
            vkLinkIdRegex.matches(this)

    private fun List<ValidationIssue>.toValidationResult(): ValidationResult =
        if (isEmpty()) ValidationResult.Valid else ValidationResult.Invalid(this)
}

sealed interface ValidationResult {
    val issues: List<ValidationIssue>
    val isValid: Boolean
        get() = issues.isEmpty()

    data object Valid : ValidationResult {
        override val issues: List<ValidationIssue> = emptyList()
    }

    data class Invalid(override val issues: List<ValidationIssue>) : ValidationResult
}

data class ValidationIssue(
    val field: String,
    val message: String,
)
