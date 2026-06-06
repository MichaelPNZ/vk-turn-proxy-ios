package com.vkturnproxy.desktop

import com.vkturnproxy.desktop.importing.DesktopProfileImporter
import com.vkturnproxy.desktop.windows.WindowsTunnelRuntime
import com.vkturnproxy.shared.model.Profile
import com.vkturnproxy.shared.validation.ConfigValidator
import com.vkturnproxy.shared.validation.ValidationResult
import java.awt.BorderLayout
import java.awt.Color
import java.awt.Dimension
import java.awt.Font
import java.awt.Toolkit
import java.awt.datatransfer.StringSelection
import javax.swing.BorderFactory
import javax.swing.Box
import javax.swing.BoxLayout
import javax.swing.JButton
import javax.swing.JFileChooser
import javax.swing.JFrame
import javax.swing.JLabel
import javax.swing.JPanel
import javax.swing.JScrollPane
import javax.swing.JTextArea
import javax.swing.JTextField
import javax.swing.SwingUtilities
import javax.swing.UIManager
import javax.swing.WindowConstants
import javax.swing.border.EmptyBorder
import java.nio.file.Path
import kotlin.concurrent.thread
import kotlin.system.exitProcess

fun main(args: Array<String>) {
    if (args.isNotEmpty()) {
        exitProcess(DesktopCli.run(args))
    }

    SwingUtilities.invokeLater {
        UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName())
        DesktopWindow().show()
    }
}

private class DesktopWindow {
    private val input = JTextArea()
    private val output = JTextArea()
    private val status = JLabel("No profile loaded")
    private val serviceExe = JTextField(WindowsTunnelRuntime.discoverServiceExecutable()?.toString().orEmpty())
    private var currentSummary: String = ""
    private var currentProfile: Profile? = null

    fun show() {
        val frame = JFrame("VK Turn Proxy")
        frame.defaultCloseOperation = WindowConstants.EXIT_ON_CLOSE
        frame.minimumSize = Dimension(860, 680)
        frame.contentPane = rootPanel()
        frame.setLocationRelativeTo(null)
        frame.isVisible = true
    }

    private fun rootPanel(): JPanel {
        val panel = JPanel(BorderLayout(14, 14))
        panel.border = EmptyBorder(16, 16, 16, 16)

        panel.add(header(), BorderLayout.NORTH)
        panel.add(content(), BorderLayout.CENTER)
        panel.add(actions(), BorderLayout.SOUTH)
        return panel
    }

    private fun header(): JPanel {
        val panel = JPanel(BorderLayout(8, 4))
        val title = JLabel("VK Turn Proxy")
        title.font = title.font.deriveFont(Font.BOLD, 20f)
        val subtitle = JLabel("Windows desktop MVP: shared profile import and validation")
        subtitle.foreground = Color(88, 88, 88)
        panel.add(title, BorderLayout.NORTH)
        panel.add(subtitle, BorderLayout.CENTER)
        panel.add(status, BorderLayout.SOUTH)
        return panel
    }

    private fun content(): JPanel {
        val panel = JPanel()
        panel.layout = BoxLayout(panel, BoxLayout.Y_AXIS)

        input.lineWrap = true
        input.wrapStyleWord = true
        input.border = EmptyBorder(8, 8, 8, 8)

        output.isEditable = false
        output.lineWrap = true
        output.wrapStyleWord = true
        output.border = EmptyBorder(8, 8, 8, 8)

        panel.add(section("Import profile", JScrollPane(input).apply {
            preferredSize = Dimension(820, 240)
        }))
        panel.add(Box.createVerticalStrut(12))
        panel.add(serviceSection())
        panel.add(Box.createVerticalStrut(12))
        panel.add(section("Runtime summary", JScrollPane(output).apply {
            preferredSize = Dimension(820, 220)
        }))
        return panel
    }

    private fun serviceSection(): JPanel {
        val panel = JPanel(BorderLayout(8, 8))
        panel.border = BorderFactory.createCompoundBorder(
            BorderFactory.createLineBorder(Color(214, 218, 224)),
            EmptyBorder(10, 10, 10, 10),
        )
        val label = JLabel("Windows service")
        label.font = label.font.deriveFont(Font.BOLD, 14f)

        val row = JPanel(BorderLayout(8, 0))
        val browse = JButton("Browse")
        browse.addActionListener { browseServiceExecutable() }
        row.add(serviceExe, BorderLayout.CENTER)
        row.add(browse, BorderLayout.EAST)

        panel.add(label, BorderLayout.NORTH)
        panel.add(row, BorderLayout.CENTER)
        return panel
    }

    private fun section(title: String, body: JScrollPane): JPanel {
        val panel = JPanel(BorderLayout(8, 8))
        panel.border = BorderFactory.createCompoundBorder(
            BorderFactory.createLineBorder(Color(214, 218, 224)),
            EmptyBorder(10, 10, 10, 10),
        )
        val label = JLabel(title)
        label.font = label.font.deriveFont(Font.BOLD, 14f)
        panel.add(label, BorderLayout.NORTH)
        panel.add(body, BorderLayout.CENTER)
        return panel
    }

    private fun actions(): JPanel {
        val panel = JPanel(BorderLayout(12, 0))
        val left = JPanel()
        val right = JPanel()

        val validate = JButton("Validate import")
        validate.addActionListener { validateImport() }

        val copy = JButton("Copy summary")
        copy.addActionListener { copySummary() }

        val clear = JButton("Clear")
        clear.addActionListener {
            input.text = ""
            output.text = ""
            currentSummary = ""
            currentProfile = null
            setStatus("No profile loaded", false)
        }

        val prepare = JButton("Prepare request")
        prepare.addActionListener { prepareWindowsStartRequest() }

        val start = JButton("Start")
        start.addActionListener { runWindowsControl("start") }

        val serviceStatus = JButton("Status")
        serviceStatus.addActionListener { runWindowsControl("status") }

        val logs = JButton("Logs")
        logs.addActionListener { runWindowsControl("logs") }

        val stop = JButton("Stop")
        stop.addActionListener { runWindowsControl("stop") }

        left.add(validate)
        left.add(copy)
        left.add(clear)
        right.add(prepare)
        right.add(start)
        right.add(serviceStatus)
        right.add(logs)
        right.add(stop)

        panel.add(left, BorderLayout.WEST)
        panel.add(right, BorderLayout.EAST)
        return panel
    }

    private fun validateImport() {
        val raw = input.text.trim()
        if (raw.isEmpty()) {
            setStatus("Paste a full backup JSON or vkturnproxy:// import link.", false)
            output.text = ""
            currentSummary = ""
            return
        }

        runCatching { parseImportedProfile(raw) }
            .onSuccess { profile ->
                when (val result = ConfigValidator.validateProfile(profile)) {
                    ValidationResult.Valid -> {
                        currentSummary = profile.toSummary()
                        currentProfile = profile
                        output.text = currentSummary
                        setStatus("Profile payload is valid.", true)
                    }

                    is ValidationResult.Invalid -> {
                        currentSummary = ""
                        currentProfile = null
                        output.text = result.issues.joinToString(separator = "\n") {
                            "${it.field}: ${it.message}"
                        }
                        setStatus("Profile payload is invalid.", false)
                    }
                }
            }
            .onFailure { error ->
                currentSummary = ""
                currentProfile = null
                output.text = error.message ?: "Profile payload is invalid."
                setStatus("Profile payload is invalid.", false)
            }
    }

    private fun prepareWindowsStartRequest() {
        val profile = currentProfile ?: run {
            setStatus("Validate a profile first.", false)
            output.text = "Validate a profile first."
            return
        }

        runCatching { WindowsTunnelRuntime.prepareStartRequest(profile) }
            .onSuccess { request ->
                val preflight = WindowsTunnelRuntime.preflight()
                output.text = buildString {
                    appendLine(currentSummary)
                    appendLine()
                    appendLine("Windows service start request")
                    appendLine("  service: ${request.serviceName}")
                    appendLine("  adapter: ${request.adapterName}")
                    appendLine("  peer: ${request.peerAddress}")
                    appendLine("  interface: ${request.interfaceAddress}")
                    appendLine("  dns: ${request.dnsServers.joinToString()}")
                    appendLine("  allowed_ips: ${request.allowedIps.joinToString()}")
                    appendLine("  wireguard_uapi_bytes: ${request.wireGuardUapi.toByteArray().size}")
                    appendLine("  proxy_json_bytes: ${request.proxyJson.toByteArray().size}")
                    appendLine()
                    appendLine("Preflight")
                    appendLine("  os: ${preflight.osName}")
                    appendLine("  ready: ${preflight.ready}")
                    preflight.blockers.forEach { appendLine("  blocker: $it") }
                    preflight.warnings.forEach { appendLine("  warning: $it") }
                    appendLine()
                    appendLine("Use CLI to write the request on Windows:")
                    appendLine("  desktopApp.bat windows-start-request --profile-file profile.txt --out start-request.json")
                }
                setStatus("Windows start request prepared.", true)
            }
            .onFailure { error ->
                output.text = error.message ?: "Could not prepare Windows start request."
                setStatus("Windows start request failed.", false)
            }
    }

    private fun runWindowsControl(command: String) {
        val servicePath = WindowsTunnelRuntime.discoverServiceExecutable(serviceExe.text)
        if (servicePath == null) {
            setStatus("Configure Windows service executable first.", false)
            output.text = "Configure path to ${WindowsTunnelRuntime.SERVICE_EXE_NAME} first."
            return
        }
        serviceExe.text = servicePath.toString()

        val requestPath = if (command == "start") {
            val profile = currentProfile ?: run {
                setStatus("Validate a profile first.", false)
                output.text = "Validate a profile before starting the tunnel."
                return
            }
            val request = runCatching { WindowsTunnelRuntime.prepareStartRequest(profile) }
                .getOrElse { error ->
                    setStatus("Windows start request failed.", false)
                    output.text = error.message ?: "Could not prepare Windows start request."
                    return
                }
            WindowsTunnelRuntime.defaultStartRequestPath().also {
                WindowsTunnelRuntime.writeStartRequest(request, it)
            }
        } else {
            null
        }

        val preflight = WindowsTunnelRuntime.preflight(serviceExecutable = servicePath)
        if (!preflight.ready) {
            output.text = buildString {
                appendLine("Windows service preflight")
                appendLine("  os: ${preflight.osName}")
                appendLine("  service_exe: $servicePath")
                preflight.blockers.forEach { appendLine("  blocker: $it") }
                preflight.warnings.forEach { appendLine("  warning: $it") }
            }
            setStatus("Windows service is not ready on this host.", false)
            return
        }

        setStatus("Windows tunnel $command requested.", true)
        output.text = "Running Windows service control command: $command"
        thread(name = "windows-service-$command", isDaemon = true) {
            val result = runCatching {
                WindowsTunnelRuntime.runServiceControl(servicePath, command, requestPath)
            }
            SwingUtilities.invokeLater {
                result
                    .onSuccess { control ->
                        output.text = buildString {
                            appendLine("Windows service control")
                            appendLine("  command: ${control.command}")
                            appendLine("  exit_code: ${control.exitCode}")
                            if (requestPath != null) appendLine("  request: $requestPath")
                            if (control.stdout.isNotBlank()) {
                                appendLine()
                                appendLine("stdout")
                                appendLine(control.stdout)
                            }
                            if (control.stderr.isNotBlank()) {
                                appendLine()
                                appendLine("stderr")
                                appendLine(control.stderr)
                            }
                        }
                        setStatus(
                            if (control.ok) "Windows tunnel $command completed." else "Windows tunnel $command failed.",
                            control.ok,
                        )
                    }
                    .onFailure { error ->
                        output.text = error.message ?: "Windows service control failed."
                        setStatus("Windows tunnel $command failed.", false)
                    }
            }
        }
    }

    private fun browseServiceExecutable() {
        val chooser = JFileChooser()
        chooser.dialogTitle = "Select ${WindowsTunnelRuntime.SERVICE_EXE_NAME}"
        chooser.fileSelectionMode = JFileChooser.FILES_ONLY
        if (chooser.showOpenDialog(null) == JFileChooser.APPROVE_OPTION) {
            serviceExe.text = chooser.selectedFile.toPath().toString()
        }
    }

    private fun copySummary() {
        if (currentSummary.isBlank()) {
            setStatus("Nothing to copy.", false)
            return
        }
        Toolkit.getDefaultToolkit()
            .systemClipboard
            .setContents(StringSelection(currentSummary), null)
        setStatus("Runtime summary copied.", true)
    }

    private fun setStatus(text: String, ok: Boolean) {
        status.text = text
        status.foreground = if (ok) Color(22, 112, 57) else Color(150, 59, 42)
    }
}

private fun parseImportedProfile(input: String): Profile = DesktopProfileImporter.parse(input)

private fun Profile.toSummary(): String = buildString {
    appendLine("Profile")
    appendLine("  id: ${id.value}")
    appendLine("  name: $name")
    appendLine("  schema: $schemaVersion")
    appendLine()
    appendLine("Proxy")
    appendLine("  peer: ${proxy.peerAddr}")
    appendLine("  mode: ${proxy.mode}")
    appendLine("  connections: ${proxy.numConns}")
    appendLine("  use_dtls: ${proxy.useDtls}")
    appendLine("  use_udp: ${proxy.useUdp}")
    proxy.turnServer?.let { appendLine("  turn_server: $it") }
    proxy.turnPort?.let { appendLine("  turn_port: $it") }
    appendLine()
    appendLine("WireGuard")
    appendLine("  interface: ${wireGuard.interfaceAddress ?: "not set"}")
    appendLine("  dns: ${wireGuard.dns.joinToString().ifBlank { "not set" }}")
    appendLine("  endpoint: ${wireGuard.endpoint ?: proxy.peerAddr}")
    appendLine("  allowed_ips: ${wireGuard.allowedIps.joinToString().ifBlank { "not set" }}")
    appendLine("  raw_config_bytes: ${wireGuard.raw.toByteArray().size}")
}

private object DesktopCli {
    fun run(args: Array<String>): Int =
        runCatching {
            when (args.firstOrNull()) {
                "validate" -> validate(args.drop(1))
                "windows-start-request" -> windowsStartRequest(args.drop(1))
                "windows-preflight" -> windowsPreflight(args.drop(1))
                "windows-service-commands" -> windowsServiceCommands(args.drop(1))
                "windows-control-start" -> windowsControl(args.drop(1), "start")
                "windows-control-status" -> windowsControl(args.drop(1), "status")
                "windows-control-stop" -> windowsControl(args.drop(1), "stop")
                "windows-control-logs" -> windowsControl(args.drop(1), "logs")
                "--help", "-h", "help", null -> {
                    printHelp()
                    0
                }
                else -> {
                    System.err.println("Unknown command: ${args.first()}")
                    printHelp()
                    2
                }
            }
        }.getOrElse { error ->
            System.err.println(error.message ?: error.toString())
            1
        }

    private fun validate(args: List<String>): Int {
        val profile = readProfile(args)
        when (val result = ConfigValidator.validateProfile(profile)) {
            ValidationResult.Valid -> {
                println(profile.toSummary())
                return 0
            }
            is ValidationResult.Invalid -> {
                result.issues.forEach { println("${it.field}: ${it.message}") }
                return 1
            }
        }
    }

    private fun windowsStartRequest(args: List<String>): Int {
        val output = option(args, "--out")?.let(Path::of)
            ?: error("Missing --out <path>.")
        val profile = readProfile(args)
        val request = WindowsTunnelRuntime.prepareStartRequest(profile)
        WindowsTunnelRuntime.writeStartRequest(request, output)
        println("Wrote Windows start request: $output")
        return 0
    }

    private fun windowsPreflight(args: List<String>): Int {
        val serviceExe = option(args, "--service-exe")?.let(Path::of)
        val result = WindowsTunnelRuntime.preflight(serviceExecutable = serviceExe)
        println("Windows preflight")
        println("  os: ${result.osName}")
        println("  is_windows: ${result.isWindows}")
        println("  service_exe: ${result.serviceExecutable ?: "not configured"}")
        println("  service_exe_exists: ${result.serviceExecutableExists}")
        result.blockers.forEach { println("  blocker: $it") }
        result.warnings.forEach { println("  warning: $it") }
        return if (result.ready) 0 else 1
    }

    private fun windowsServiceCommands(args: List<String>): Int {
        val serviceExe = option(args, "--service-exe")?.let(Path::of)
            ?: error("Missing --service-exe <path>.")
        WindowsTunnelRuntime.serviceInstallCommands(serviceExe).forEach(::println)
        return 0
    }

    private fun windowsControl(args: List<String>, command: String): Int {
        val serviceExe = WindowsTunnelRuntime.discoverServiceExecutable(option(args, "--service-exe"))
            ?: error("Missing --service-exe <path> or VKTURN_SERVICE_EXE.")
        val requestPath = if (command == "start") {
            option(args, "--request")?.let(Path::of) ?: run {
                val profile = readProfile(args)
                val request = WindowsTunnelRuntime.prepareStartRequest(profile)
                WindowsTunnelRuntime.defaultStartRequestPath().also {
                    WindowsTunnelRuntime.writeStartRequest(request, it)
                }
            }
        } else {
            null
        }
        val result = WindowsTunnelRuntime.runServiceControl(serviceExe, command, requestPath)
        println(result.stdout.ifBlank { result.stderr })
        return result.exitCode
    }

    private fun readProfile(args: List<String>): Profile {
        val profileFile = option(args, "--profile-file")?.let(Path::of)
            ?: error("Missing --profile-file <path>.")
        return DesktopProfileImporter.parse(profileFile.toFile().readText())
    }

    private fun option(args: List<String>, name: String): String? {
        val index = args.indexOf(name)
        return if (index >= 0 && index + 1 < args.size) args[index + 1] else null
    }

    private fun printHelp() {
        println(
            """
            VK Turn Proxy desktop commands:
              validate --profile-file <path>
              windows-start-request --profile-file <path> --out <path>
              windows-preflight [--service-exe <path>]
              windows-service-commands --service-exe <path>
              windows-control-start --service-exe <path> (--profile-file <path> | --request <path>)
              windows-control-status --service-exe <path>
              windows-control-stop --service-exe <path>
              windows-control-logs --service-exe <path>
            """.trimIndent(),
        )
    }
}
