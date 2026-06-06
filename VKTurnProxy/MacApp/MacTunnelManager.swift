import Foundation
@preconcurrency import NetworkExtension

private let defaultNumConnections = 10

struct MacDiagnosticEvent: Identifiable {
    let id = UUID()
    let line: String
}

struct MacParsedProfile {
    let privateKey: String
    let peerPublicKey: String
    let presharedKey: String
    let tunnelAddress: String
    let dnsServers: String
    let allowedIPs: String
    let vkLink: String
    let peerAddress: String
    let useDTLS: Bool
    let useSrtp: Bool
    let useUDP: Bool
    let useWrapA: Bool
    let wrapAPassword: String
    let numConnections: Int
}

@MainActor
final class MacTunnelManager: ObservableObject {
    @Published var status: NEVPNStatus = .disconnected
    @Published var errorMessage: String?
    @Published var loadedProfile: MacParsedProfile?
    @Published private(set) var diagnostics: [MacDiagnosticEvent] = []
    @Published private(set) var sharedLogText = ""

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private let maxDiagnosticEvents = 250
    private let maxSharedLogCharacters = 120_000

    init() {
        log(.info, "macOS app started")
        refreshSharedLogs()
        Task {
            await loadManager()
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    var statusText: String {
        switch status {
        case .invalid: return "Invalid"
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        @unknown default: return "Unknown"
        }
    }

    var canConnect: Bool {
        loadedProfile != nil && status != .connected && status != .connecting && status != .reasserting
    }

    var canDisconnect: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    func loadProfile(raw: String) {
        do {
            loadedProfile = try Self.parseProfile(raw)
            errorMessage = nil
            log(.info, "profile loaded")
        } catch {
            loadedProfile = nil
            errorMessage = error.localizedDescription
            log(.error, "profile load failed: \(error.localizedDescription)")
        }
    }

    func connect() async {
        guard let profile = loadedProfile else {
            errorMessage = "Load a valid profile before connecting."
            log(.warning, "connect rejected: no valid profile loaded")
            return
        }

        do {
            log(.info, "connect requested")
            let manager = try await getOrCreateManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = "com.vkturnproxy.mac.tunnel"
            proto.serverAddress = profile.peerAddress
            proto.providerConfiguration = [
                "wg_config": try buildUAPIConfig(profile),
                "proxy_config": try buildProxyConfig(profile),
                "tunnel_address": profile.tunnelAddress,
                "dns_servers": profile.dnsServers,
                "mtu": "1280",
                "use_wrap_a": profile.useWrapA,
            ]

            manager.protocolConfiguration = proto
            manager.localizedDescription = "VK TURN Proxy"
            manager.isEnabled = true

            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel()
            errorMessage = nil
            log(.info, "vpn tunnel start requested")
        } catch {
            errorMessage = error.localizedDescription
            log(.error, "connect failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        log(.info, "disconnect requested")
        manager?.connection.stopVPNTunnel()
    }

    func recordImportOpened() {
        log(.info, "profile file opened")
    }

    func recordProfileInputCleared() {
        log(.info, "profile input cleared")
    }

    func recordValidation(ok: Bool, message: String) {
        log(ok ? .info : .warning, ok ? "profile validation passed" : "profile validation failed: \(message)")
    }

    func clearDiagnostics() {
        diagnostics.removeAll()
        sharedLogText = ""
        SharedLogger.shared.clearLogs()
    }

    func recordDiagnosticsCopied() {
        log(.info, "diagnostics copied")
    }

    func recordDiagnosticsExported(fileName: String) {
        log(.info, "diagnostics exported: \(fileName)")
    }

    func recordDiagnosticsExportFailed(_ error: Error) {
        errorMessage = error.localizedDescription
        log(.error, "diagnostics export failed: \(error.localizedDescription)")
    }

    var diagnosticsText: String {
        let localText = diagnostics.map(\.line).joined(separator: "\n")
        if localText.isEmpty {
            return sharedLogText
        }
        if sharedLogText.isEmpty {
            return localText
        }
        return localText + "\n\n--- Shared VPN log ---\n" + sharedLogText
    }

    func refreshSharedLogs() {
        let text = SharedLogger.shared.readLogs()
        if text.isEmpty {
            let status = SharedLogger.shared.inspectStorage()
            if status.hasContainer {
                sharedLogText = """
                [shared-logdiag] vpn.log exists=\(status.currentExists) bytes=\(status.currentBytes)
                [shared-logdiag] vpn.log.1 exists=\(status.archivedExists) bytes=\(status.archivedBytes)
                [shared-logdiag] container=\(status.containerPath)
                """
            } else {
                sharedLogText = "[shared-logdiag] App Group container unavailable"
            }
            return
        }
        sharedLogText = tail(text, maxCharacters: maxSharedLogCharacters)
    }

    private func loadManager() async {
        do {
            log(.info, "loading saved VPN preferences")
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { manager in
                guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                    return false
                }
                return proto.providerBundleIdentifier == "com.vkturnproxy.mac.tunnel"
            }
            if let manager {
                status = manager.connection.status
                log(.info, "saved VPN manager loaded: \(statusText)")
                observeStatus(manager)
            } else {
                log(.info, "no saved VPN manager found")
            }
        } catch {
            errorMessage = error.localizedDescription
            log(.error, "load preferences failed: \(error.localizedDescription)")
        }
    }

    private func getOrCreateManager() async throws -> NETunnelProviderManager {
        if let manager {
            observeStatus(manager)
            return manager
        }
        let newManager = NETunnelProviderManager()
        manager = newManager
        observeStatus(newManager)
        return newManager
    }

    private func observeStatus(_ manager: NETunnelProviderManager) {
        if statusObserver != nil {
            return
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.status = manager.connection.status
                self.log(.info, "vpn status changed: \(self.statusText)")
            }
        }
    }

    private func log(_ level: MacDiagnosticLevel, _ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(message)"
        diagnostics.append(MacDiagnosticEvent(line: line))
        SharedLogger.shared.log("[MacApp] \(message)")
        if diagnostics.count > maxDiagnosticEvents {
            diagnostics.removeFirst(diagnostics.count - maxDiagnosticEvents)
        }
    }

    private func tail(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else {
            return text
        }
        return "[shared-logdiag] truncated to last \(maxCharacters) characters\n" + String(text.suffix(maxCharacters))
    }
}

private enum MacDiagnosticLevel: String {
    case info = "info"
    case warning = "warning"
    case error = "error"
}

private extension MacTunnelManager {
    static func parseProfile(_ rawInput: String) throws -> MacParsedProfile {
        let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw MacProfileError.empty
        }

        let data: Data
        if raw.hasPrefix("vkturnproxy:") {
            data = try decodeConnectionLink(raw)
        } else {
            guard let rawData = raw.data(using: .utf8) else {
                throw MacProfileError.invalidJSON
            }
            data = rawData
        }

        let decoder = JSONDecoder()
        if let full = try? decoder.decode(MacLegacyFullBackup.self, from: data) {
            guard full.version == 1, full.type == "full" else {
                throw MacProfileError.unsupported
            }
            return full.settings.toProfile()
        }
        if let link = try? decoder.decode(MacLegacyConnectionLink.self, from: data) {
            guard link.version == 1, link.type == "connection" else {
                throw MacProfileError.unsupported
            }
            return link.settings.toProfile()
        }
        throw MacProfileError.invalidJSON
    }

    static func decodeConnectionLink(_ raw: String) throws -> Data {
        let query = raw.components(separatedBy: "?").dropFirst().joined(separator: "?")
        guard let item = query
            .split(separator: "&")
            .first(where: { $0.split(separator: "=", maxSplits: 1).first == "data" }) else {
            throw MacProfileError.invalidConnectionLink
        }
        let encoded = String(item).components(separatedBy: "=").dropFirst().joined(separator: "=")
        guard let percentDecoded = encoded.removingPercentEncoding else {
            throw MacProfileError.invalidConnectionLink
        }
        var normalized = percentDecoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - normalized.count % 4) % 4
        normalized += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: normalized) else {
            throw MacProfileError.invalidConnectionLink
        }
        return data
    }

    func buildUAPIConfig(_ profile: MacParsedProfile) throws -> String {
        if profile.useWrapA {
            return ""
        }
        var lines: [String] = []
        lines.append("private_key=\(try parseWireGuardKey(profile.privateKey, field: "Private Key"))")
        lines.append("replace_peers=true")
        lines.append("public_key=\(try parseWireGuardKey(profile.peerPublicKey, field: "Peer Public Key"))")
        lines.append("endpoint=\(profile.peerAddress)")
        for allowedIP in profile.allowedIPs.split(separator: ",") {
            lines.append("allowed_ip=\(allowedIP.trimmingCharacters(in: .whitespaces))")
        }
        if !profile.presharedKey.isEmpty {
            lines.append("preshared_key=\(try parseWireGuardKey(profile.presharedKey, field: "Preshared Key"))")
        }
        return lines.joined(separator: "\n")
    }

    func buildProxyConfig(_ profile: MacParsedProfile) throws -> String {
        let payload: [String: Any] = [
            "peer_addr": profile.peerAddress,
            "vk_link": profile.vkLink,
            "num_conns": profile.numConnections,
            "use_dtls": profile.useDTLS,
            "use_udp": profile.useUDP,
            "use_srtp": profile.useSrtp,
            "use_wrap_a": profile.useWrapA,
            "wrap_a_password": profile.wrapAPassword,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MacProfileError.invalidJSON
        }
        return json
    }

    func parseWireGuardKey(_ input: String, field: String) throws -> String {
        var cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !cleaned.isEmpty else {
            throw MacProfileError.keyError("\(field) is empty.")
        }
        guard let data = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]) else {
            throw MacProfileError.keyError("\(field) is not valid Base64.")
        }
        guard data.count == 32 else {
            throw MacProfileError.keyError("\(field) decoded to \(data.count) bytes, expected 32.")
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

private struct MacLegacyFullBackup: Decodable {
    let version: Int
    let type: String
    let settings: MacLegacySettings
}

private struct MacLegacyConnectionLink: Decodable {
    let version: Int
    let type: String
    let settings: MacLegacySettings
}

private struct MacLegacySettings: Decodable {
    let privateKey: String?
    let peerPublicKey: String?
    let presharedKey: String?
    let tunnelAddress: String?
    let dnsServers: String?
    let allowedIPs: String?
    let vkLink: String
    let peerAddress: String
    let useDTLS: Bool?
    let useSrtp: Bool?
    let useUDP: Bool?
    let useWrapA: Bool?
    let wrapAPassword: String?
    let numConnections: Int?

    func toProfile() -> MacParsedProfile {
        MacParsedProfile(
            privateKey: privateKey ?? "",
            peerPublicKey: peerPublicKey ?? "",
            presharedKey: presharedKey ?? "",
            tunnelAddress: tunnelAddress ?? "192.168.102.3/24",
            dnsServers: dnsServers ?? "1.1.1.1",
            allowedIPs: allowedIPs ?? "0.0.0.0/0",
            vkLink: vkLink,
            peerAddress: peerAddress,
            useDTLS: useDTLS ?? true,
            useSrtp: useSrtp ?? true,
            useUDP: useUDP ?? false,
            useWrapA: useWrapA ?? false,
            wrapAPassword: wrapAPassword ?? "",
            numConnections: numConnections ?? defaultNumConnections,
        )
    }
}

private enum MacProfileError: LocalizedError {
    case empty
    case invalidJSON
    case invalidConnectionLink
    case unsupported
    case keyError(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste backup JSON or vkturnproxy:// link."
        case .invalidJSON:
            return "Profile payload is not valid backup or connection JSON."
        case .invalidConnectionLink:
            return "Connection link is missing or has invalid data payload."
        case .unsupported:
            return "Profile version or type is not supported."
        case .keyError(let message):
            return message
        }
    }
}
