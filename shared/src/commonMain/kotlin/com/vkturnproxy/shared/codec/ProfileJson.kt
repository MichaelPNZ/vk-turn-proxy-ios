package com.vkturnproxy.shared.codec

import com.vkturnproxy.shared.model.Profile
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

object ProfileJson {
    val json: Json = Json {
        encodeDefaults = true
        explicitNulls = false
        ignoreUnknownKeys = true
        prettyPrint = true
    }

    fun encode(profile: Profile): String = json.encodeToString(profile)

    fun decode(raw: String): Profile = json.decodeFromString(raw)
}
