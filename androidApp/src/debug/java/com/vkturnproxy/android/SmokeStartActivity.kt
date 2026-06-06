package com.vkturnproxy.android

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import com.vkturnproxy.shared.model.ProfileId

class SmokeStartActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (intent.action == ACTION_STOP) {
            startService(
                Intent(this, AndroidVpnService::class.java)
                    .setAction(AndroidVpnService.ACTION_STOP),
            )
            finish()
            return
        }

        val permissionIntent = VpnService.prepare(this)
        if (permissionIntent != null) {
            AndroidVpnRuntime.update(AndroidVpnStatus.Error("VPN permission must be granted through the UI before debug smoke."))
            finish()
            return
        }

        runCatching {
            val importText = intent.getStringExtra(EXTRA_IMPORT_TEXT).orEmpty()
            require(importText.isNotBlank()) { "Missing $EXTRA_IMPORT_TEXT extra." }
            parseImportedProfile(
                input = importText,
                id = ProfileId("android-debug-smoke"),
                name = "Debug smoke profile",
            ).toVpnProfilePayload()
        }.onSuccess { payload ->
            val serviceIntent = Intent(this, AndroidVpnService::class.java)
                .setAction(AndroidVpnService.ACTION_START)
            payload.putInto(serviceIntent)
            startService(serviceIntent)
        }.onFailure { error ->
            AndroidVpnRuntime.update(AndroidVpnStatus.Error(error.message ?: "Debug smoke import failed."))
        }
        finish()
    }

    companion object {
        const val ACTION_STOP = "com.vkturnproxy.android.debug.STOP"
        const val EXTRA_IMPORT_TEXT = "com.vkturnproxy.android.debug.IMPORT_TEXT"
    }
}
