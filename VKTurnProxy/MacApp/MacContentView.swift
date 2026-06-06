import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VKTurnShared

struct MacContentView: View {
    @StateObject private var tunnelManager = MacTunnelManager()
    @State private var importText = ""
    @State private var validationMessage = "No profile loaded"
    @State private var validationOK = false
    @State private var showingFileImporter = false

    var body: some View {
        NavigationSplitView {
            List {
                Label("Profile", systemImage: "person.crop.circle")
                Label("Transport", systemImage: "point.3.connected.trianglepath.dotted")
                Label("Logs", systemImage: "doc.text")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(alignment: .leading, spacing: 18) {
                header
                profilePanel
                transportPanel
                diagnosticsPanel
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(minWidth: 720, minHeight: 520)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false,
        ) { result in
            handleImportResult(result)
        }
        .onAppear {
            tunnelManager.refreshSharedLogs()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VK Turn Proxy")
                .font(.system(size: 28, weight: .semibold))
            Text("macOS TestFlight MVP")
                .foregroundStyle(.secondary)
        }
    }

    private var profilePanel: some View {
        GroupBox("Profile") {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $importText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 190)
                    .overlay {
                        if importText.isEmpty {
                            Text("Paste backup JSON or vkturnproxy:// link")
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                HStack(spacing: 10) {
                    Button("Open") {
                        showingFileImporter = true
                    }
                    Button("Validate") {
                        validateImport()
                    }
                    Button("Clear") {
                        importText = ""
                        validationMessage = "No profile loaded"
                        validationOK = false
                        tunnelManager.loadedProfile = nil
                        tunnelManager.recordProfileInputCleared()
                    }
                    Spacer()
                }

                Label(validationMessage, systemImage: validationOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(validationOK ? .green : .orange)
                    .textSelection(.enabled)
            }
            .padding(4)
        }
    }

    private var diagnosticsPanel: some View {
        GroupBox("Logs") {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    Text(tunnelManager.diagnosticsText.isEmpty ? "No diagnostics yet" : tunnelManager.diagnosticsText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(tunnelManager.diagnosticsText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                }
                .frame(minHeight: 120, maxHeight: 160)

                HStack(spacing: 10) {
                    Button("Refresh") {
                        tunnelManager.refreshSharedLogs()
                    }

                    Button("Copy") {
                        copyDiagnostics()
                    }
                    .disabled(tunnelManager.diagnosticsText.isEmpty)

                    Button("Export") {
                        exportDiagnostics()
                    }
                    .disabled(tunnelManager.diagnosticsText.isEmpty)

                    Button("Clear") {
                        tunnelManager.clearDiagnostics()
                    }
                    .disabled(tunnelManager.diagnosticsText.isEmpty)

                    Spacer()
                }
            }
            .padding(4)
        }
    }

    private var transportPanel: some View {
        GroupBox("Transport") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Status")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(tunnelManager.statusText)
                        .fontWeight(.medium)
                }
                HStack {
                    Text("Profile")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(tunnelManager.loadedProfile == nil ? "Not loaded" : "Loaded")
                        .fontWeight(.medium)
                }
                if let errorMessage = tunnelManager.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Button("Connect") {
                        Task {
                            await tunnelManager.connect()
                        }
                    }
                    .disabled(!tunnelManager.canConnect)
                    Button("Disconnect") {
                        tunnelManager.disconnect()
                    }
                    .disabled(!tunnelManager.canDisconnect)
                }
            }
            .padding(4)
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                return
            }
            let needsScope = url.startAccessingSecurityScopedResource()
            defer {
                if needsScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            importText = try String(contentsOf: url, encoding: .utf8)
            tunnelManager.recordImportOpened()
            validateImport()
        } catch {
            validationMessage = error.localizedDescription
            validationOK = false
            tunnelManager.recordValidation(ok: false, message: error.localizedDescription)
        }
    }

    private func validateImport() {
        let raw = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            validationMessage = "Paste backup JSON or vkturnproxy:// link"
            validationOK = false
            tunnelManager.loadedProfile = nil
            tunnelManager.recordValidation(ok: false, message: validationMessage)
            return
        }

        let error: String?
        if raw.hasPrefix("{") {
            error = IosImportValidator.shared.validateFullBackup(rawJson: raw)
        } else {
            error = IosImportValidator.shared.validateConnectionLink(raw: raw)
        }
        validationOK = error == nil
        validationMessage = error ?? "Profile payload is valid"
        tunnelManager.recordValidation(ok: validationOK, message: validationMessage)
        if validationOK {
            tunnelManager.loadProfile(raw: raw)
        } else {
            tunnelManager.loadedProfile = nil
        }
    }

    private func copyDiagnostics() {
        tunnelManager.refreshSharedLogs()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tunnelManager.diagnosticsText, forType: .string)
        tunnelManager.recordDiagnosticsCopied()
    }

    private func exportDiagnostics() {
        tunnelManager.refreshSharedLogs()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "vk-turn-proxy-macos-diagnostics.log"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }
            do {
                try tunnelManager.diagnosticsText.write(to: url, atomically: true, encoding: .utf8)
                tunnelManager.recordDiagnosticsExported(fileName: url.lastPathComponent)
            } catch {
                tunnelManager.recordDiagnosticsExportFailed(error)
            }
        }
    }
}

#Preview {
    MacContentView()
}
