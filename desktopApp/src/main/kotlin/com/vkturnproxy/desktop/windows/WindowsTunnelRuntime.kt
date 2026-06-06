package com.vkturnproxy.desktop.windows

import com.vkturnproxy.shared.model.Profile
import com.vkturnproxy.shared.runtime.ProfileRuntimeMapper
import com.vkturnproxy.shared.validation.ConfigValidator
import com.vkturnproxy.shared.validation.ValidationResult
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.absolutePathString

@Serializable
data class WindowsTunnelStartRequest(
    val schemaVersion: Int = 1,
    val serviceName: String,
    val adapterName: String,
    val profileId: String,
    val profileName: String,
    val peerAddress: String,
    val interfaceAddress: String,
    val dnsServers: List<String>,
    val allowedIps: List<String>,
    val wireGuardUapi: String,
    val proxyJson: String,
)

data class WindowsPreflightResult(
    val osName: String,
    val isWindows: Boolean,
    val serviceExecutable: Path?,
    val serviceExecutableExists: Boolean,
    val blockers: List<String>,
    val warnings: List<String>,
) {
    val ready: Boolean
        get() = blockers.isEmpty()
}

data class WindowsControlResult(
    val command: String,
    val exitCode: Int,
    val stdout: String,
    val stderr: String,
) {
    val ok: Boolean
        get() = exitCode == 0
}

object WindowsTunnelRuntime {
    const val DEFAULT_SERVICE_NAME = "VKTurnProxyTunnel"
    const val DEFAULT_ADAPTER_NAME = "VK Turn Proxy"
    const val SERVICE_EXE_NAME = "vk-turn-proxy-windows-service.exe"

    private val json = Json {
        prettyPrint = true
        encodeDefaults = true
    }

    fun prepareStartRequest(
        profile: Profile,
        serviceName: String = DEFAULT_SERVICE_NAME,
        adapterName: String = DEFAULT_ADAPTER_NAME,
    ): WindowsTunnelStartRequest {
        when (val validation = ConfigValidator.validateProfile(profile)) {
            ValidationResult.Valid -> Unit
            is ValidationResult.Invalid -> {
                val message = validation.issues.joinToString(separator = "; ") {
                    "${it.field}: ${it.message}"
                }
                error("Profile is invalid: $message")
            }
        }

        val payload = ProfileRuntimeMapper.toRuntimePayload(profile)
        return WindowsTunnelStartRequest(
            serviceName = serviceName,
            adapterName = adapterName,
            profileId = profile.id.value,
            profileName = profile.name,
            peerAddress = profile.proxy.peerAddr,
            interfaceAddress = payload.interfaceAddress,
            dnsServers = payload.dnsServers,
            allowedIps = payload.allowedIps,
            wireGuardUapi = payload.wireGuardUapi,
            proxyJson = payload.proxyJson,
        )
    }

    fun encodeStartRequest(request: WindowsTunnelStartRequest): String =
        json.encodeToString(request)

    fun writeStartRequest(request: WindowsTunnelStartRequest, output: Path) {
        output.parent?.let { Files.createDirectories(it) }
        Files.writeString(output, encodeStartRequest(request))
    }

    fun defaultStartRequestPath(): Path =
        Path.of(System.getProperty("user.home"), ".vkturnproxy", "windows", "start-request.json")

    fun discoverServiceExecutable(
        userConfigured: String? = null,
        workingDir: Path = Path.of(System.getProperty("user.dir")),
    ): Path? {
        val explicit = userConfigured?.trim()?.takeIf { it.isNotEmpty() }?.let(Path::of)
        if (explicit != null) return explicit

        System.getProperty("vkturnproxy.serviceExe")?.trim()?.takeIf { it.isNotEmpty() }?.let {
            return Path.of(it)
        }
        System.getenv("VKTURN_SERVICE_EXE")?.trim()?.takeIf { it.isNotEmpty() }?.let {
            return Path.of(it)
        }

        return listOf(
            workingDir.resolve("bin").resolve(SERVICE_EXE_NAME),
            workingDir.resolve("..").resolve("bin").resolve(SERVICE_EXE_NAME),
            workingDir.resolve("..").resolve("..").resolve("bin").resolve(SERVICE_EXE_NAME),
            workingDir.resolve("build").resolve("windows").resolve(SERVICE_EXE_NAME),
        ).firstOrNull { Files.isRegularFile(it.normalize()) }?.normalize()
    }

    fun preflight(
        osName: String = System.getProperty("os.name"),
        serviceExecutable: Path? = null,
    ): WindowsPreflightResult {
        val isWindows = osName.contains("Windows", ignoreCase = true)
        val executableExists = serviceExecutable?.let { Files.isRegularFile(it) } ?: false
        val blockers = buildList {
            if (!isWindows) {
                add("Run Windows tunnel service checks on a Windows host.")
            }
            if (serviceExecutable == null) {
                add("Windows tunnel service executable path is not configured.")
            } else if (!executableExists) {
                add("Windows tunnel service executable does not exist: $serviceExecutable")
            }
        }
        val warnings = buildList {
            add("wintun.dll availability and Wintun adapter creation must be verified on the target Windows host.")
            add("Administrator privileges are required to install/start the Windows service.")
            add("Runtime zip includes service install scripts; EXE installer source exists, but installer build/sign smoke must run on Windows.")
        }
        return WindowsPreflightResult(
            osName = osName,
            isWindows = isWindows,
            serviceExecutable = serviceExecutable,
            serviceExecutableExists = executableExists,
            blockers = blockers,
            warnings = warnings,
        )
    }

    fun serviceInstallCommands(
        serviceExecutable: Path,
        serviceName: String = DEFAULT_SERVICE_NAME,
    ): List<String> {
        val exe = serviceExecutable.toAbsolutePath().toString()
        val status = "C:\\ProgramData\\VKTurnProxy\\status.json"
        val log = "C:\\ProgramData\\VKTurnProxy\\service.log"
        return listOf(
            "sc.exe create $serviceName binPath= \"\\\"$exe\\\" -mode service -status-file \\\"$status\\\" -logfile \\\"$log\\\"\" start= demand DisplayName= \"VK Turn Proxy Tunnel\"",
            "sc.exe description $serviceName \"VK Turn Proxy privileged tunnel service\"",
            "sc.exe start $serviceName",
            "\"$exe\" -mode control-start -request \"C:\\ProgramData\\VKTurnProxy\\start-request.json\"",
            "\"$exe\" -mode control-status",
            "\"$exe\" -mode control-logs",
            "\"$exe\" -mode control-stop",
            "sc.exe stop $serviceName",
        )
    }

    fun controlCommandArgs(
        serviceExecutable: Path,
        command: String,
        requestPath: Path? = null,
    ): List<String> = buildList {
        add(serviceExecutable.absolutePathString())
        add("-mode")
        add(
            when (command) {
                "start" -> "control-start"
                "status" -> "control-status"
                "stop" -> "control-stop"
                "logs" -> "control-logs"
                else -> error("Unknown Windows tunnel control command: $command")
            },
        )
        if (requestPath != null) {
            add("-request")
            add(requestPath.absolutePathString())
        }
    }

    fun runServiceControl(
        serviceExecutable: Path,
        command: String,
        requestPath: Path? = null,
    ): WindowsControlResult {
        val args = controlCommandArgs(serviceExecutable, command, requestPath)
        val process = ProcessBuilder(args)
            .redirectErrorStream(false)
            .start()
        val stdout = process.inputStream.bufferedReader().readText()
        val stderr = process.errorStream.bufferedReader().readText()
        val exit = process.waitFor()
        return WindowsControlResult(
            command = args.joinToString(" "),
            exitCode = exit,
            stdout = stdout.trim(),
            stderr = stderr.trim(),
        )
    }
}
