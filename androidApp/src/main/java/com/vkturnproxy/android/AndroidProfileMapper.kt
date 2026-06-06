package com.vkturnproxy.android

import com.vkturnproxy.shared.codec.LegacyIosConfig
import com.vkturnproxy.shared.model.Profile
import com.vkturnproxy.shared.model.ProfileId
import com.vkturnproxy.shared.runtime.ProfileRuntimeMapper

internal fun parseImportedProfile(
    input: String,
    id: ProfileId,
    name: String,
): Profile = when {
    input.startsWith("vkturnproxy:", ignoreCase = true) ->
        LegacyIosConfig.profileFromConnectionLinkString(input, id, name)
    input.startsWith("{") ->
        runCatching { LegacyIosConfig.profileFromFullBackup(input, id, name) }
            .getOrElse { LegacyIosConfig.profileFromConnectionLinkJson(input, id, name) }
    else -> LegacyIosConfig.profileFromConnectionLinkString(input, id, name)
}

internal fun Profile.toVpnProfilePayload(): VpnProfilePayload =
    ProfileRuntimeMapper.toRuntimePayload(this).let { payload ->
        VpnProfilePayload(
            wireGuardConfig = payload.wireGuardUapi,
            interfaceAddress = payload.interfaceAddress,
            dnsServers = payload.dnsServers,
            allowedIps = payload.allowedIps,
            proxyConfig = payload.proxyJson,
        )
    }
