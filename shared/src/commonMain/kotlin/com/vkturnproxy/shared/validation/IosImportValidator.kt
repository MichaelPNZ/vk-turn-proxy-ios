package com.vkturnproxy.shared.validation

import com.vkturnproxy.shared.codec.LegacyIosConfig
import com.vkturnproxy.shared.model.ProfileId

object IosImportValidator {
    fun validateFullBackup(rawJson: String): String? =
        validateCatching {
            LegacyIosConfig.profileFromFullBackup(
                rawJson = rawJson,
                id = ProfileId("ios-import"),
                name = "iOS Import",
            )
        }

    fun validateConnectionLink(raw: String): String? =
        validateCatching {
            LegacyIosConfig.profileFromConnectionLinkString(
                raw = raw,
                id = ProfileId("ios-link"),
                name = "iOS Link",
            )
        }

    private inline fun validateCatching(buildProfile: () -> com.vkturnproxy.shared.model.Profile): String? =
        runCatching {
            when (val result = ConfigValidator.validateProfile(buildProfile())) {
                is ValidationResult.Valid -> null
                is ValidationResult.Invalid -> result.issues.joinToString("; ") { issue ->
                    "${issue.field}: ${issue.message}"
                }
            }
        }.getOrElse { error ->
            error.message ?: "Shared import validation failed"
        }
}
