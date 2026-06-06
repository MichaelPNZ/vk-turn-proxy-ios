package com.vkturnproxy.desktop.importing

import com.vkturnproxy.shared.codec.LegacyIosConfig
import com.vkturnproxy.shared.model.Profile
import com.vkturnproxy.shared.model.ProfileId

object DesktopProfileImporter {
    fun parse(input: String): Profile {
        val trimmed = input.trim()
        require(trimmed.isNotEmpty()) { "Profile payload is empty." }
        return when {
            trimmed.startsWith("vkturnproxy:", ignoreCase = true) ->
                LegacyIosConfig.profileFromConnectionLinkString(trimmed, ProfileId("desktop-import"), "Desktop import")

            trimmed.startsWith("{") ->
                runCatching {
                    LegacyIosConfig.profileFromFullBackup(trimmed, ProfileId("desktop-import"), "Desktop import")
                }.getOrElse {
                    LegacyIosConfig.profileFromConnectionLinkJson(trimmed, ProfileId("desktop-import"), "Desktop import")
                }

            else ->
                LegacyIosConfig.profileFromConnectionLinkString(trimmed, ProfileId("desktop-import"), "Desktop import")
        }
    }
}
