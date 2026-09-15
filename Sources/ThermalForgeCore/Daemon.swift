//
//  Daemon.swift
//  ThermalForge
//
//  Privileged daemon that runs as root via launchd.
//  Listens on a Unix socket so the app can control fans without sudo.
//

import Darwin
import Foundation
import IOKit.pwr_mgt

// MARK: - Constants

public enum ThermalForgeDaemon {
    public static let socketPath = "/var/run/thermalforge.sock"
    public static let plistPath = "/Library/LaunchDaemons/com.thermalforge.daemon.plist"
    public static let installPath = "/Library/PrivilegedHelperTools/com.thermalforge/thermalforge"
    public static let cliPath = "/usr/local/bin/thermalforge"
    public static let recoveryLabel = "com.thermalforge.recovery"
    public static let recoveryPlistPath = "/Library/LaunchDaemons/com.thermalforge.recovery.plist"
    public static let stateDirectory = "/Library/Application Support/ThermalForge"
    public static let label = "com.thermalforge.daemon"

    /// Bounded read-only health check; observation never renews a lease.
    public static var isRunning: Bool {
        guard let data = try? JSONEncoder().encode(BackendRequest(operation: .status)),
              let response = try? UnixSocketTransport.roundTrip(data, path: socketPath),
              let decoded = try? JSONDecoder().decode(BackendResponse.self, from: response) else { return false }
        return decoded.ok && decoded.version == 2
    }

}

// MARK: - Daemon Client

public enum DaemonError: Error, CustomStringConvertible {
    case notRunning
    case connectionFailed
    case timedOut
    case protocolError(String)
    case commandFailed(code: String, message: String)

    public var description: String {
        switch self {
        case .notRunning:
            return "ThermalForge daemon is not running. Run: sudo thermalforge install"
        case .connectionFailed:
            return "Failed to connect to daemon socket"
        case .timedOut:
            return "Daemon did not respond in time"
        case .protocolError(let msg):
            return "Daemon protocol error: \(msg)"
        case .commandFailed(let code, let message):
            return "Daemon error [\(code)]: \(message)"
        }
    }
}

public final class DaemonClient {
    private let socketPath: String
    /// Hard ceiling on a single daemon round-trip. A misbehaving or busy daemon
    /// (e.g. a slow SMC unlock) can never block the caller longer than this.
    private let timeoutSeconds: Int

    public init(socketPath: String = ThermalForgeDaemon.socketPath, timeoutSeconds: Int = 2) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    /// Backward-compatible string command transport.
    public func send(_ command: String) throws -> String {
        let request = try legacyCommandToRequest(command)
        let response = try send(request)
        if response.ok {
            if let status = response.status {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.keyEncodingStrategy = .convertToSnakeCase
                let data = try encoder.encode(status)
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            return response.message ?? "ok"
        }
        let err = response.error ?? DaemonErrorPayload(code: "daemon_error", message: response.message ?? "unknown")
        throw DaemonError.commandFailed(code: err.code, message: err.message)
    }

    public func send(_ request: DaemonRequest) throws -> DaemonResponse {
        do {
            return try sendTyped(request)
        } catch let error as DaemonError {
            if shouldRetryLegacy(error: error, for: request),
               let legacyCommand = legacyCommand(for: request)
            {
                return try sendLegacy(legacyCommand, requestID: request.requestID, command: request.command)
            }
            throw error
        }
    }

    private func sendTyped(_ request: DaemonRequest) throws -> DaemonResponse {
        let payload = try DaemonCodec.encodeRequest(request)
        let responseData = try roundTrip(payload)

        if let typedResponse = try? DaemonCodec.decodeResponse(responseData) {
            return typedResponse
        }

        // Fallback for old daemon responses.
        let fallback = String(decoding: responseData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if fallback.hasPrefix("error:") {
            throw DaemonError.commandFailed(code: "legacy_error", message: String(fallback.dropFirst(6)).trimmingCharacters(in: .whitespaces))
        }
        return DaemonResponse(requestID: request.requestID, ok: true, message: fallback)
    }

    private func roundTrip(_ payload: Data) throws -> Data {
        try UnixSocketTransport.roundTrip(payload, path: socketPath, timeout: TimeInterval(timeoutSeconds))
    }

    private func shouldRetryLegacy(error: DaemonError, for request: DaemonRequest) -> Bool {
        guard ["status", "auto"].contains(request.command), legacyCommand(for: request) != nil else { return false }
        switch error {
        case .commandFailed(let code, let message):
            return code == "legacy_error" && message.contains("unknown command")
        default:
            return false
        }
    }

    private func legacyCommand(for request: DaemonRequest) -> String? {
        switch request.command {
        case "max", "auto", "status", "heartbeat":
            return request.command
        case "set":
            guard let rpm = request.rpm else { return nil }
            return "set \(rpm)"
        default:
            return nil
        }
    }

    private func sendLegacy(_ command: String, requestID: String, command originalCommand: String) throws -> DaemonResponse {
        let raw = try sendLegacyRaw(command)
        if raw.hasPrefix("error:") {
            throw DaemonError.commandFailed(
                code: "legacy_error",
                message: String(raw.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            )
        }

        if originalCommand == "status",
           let data = raw.data(using: .utf8),
           let status = try? JSONDecoder().decode(ThermalStatus.self, from: data)
        {
            return DaemonResponse(requestID: requestID, ok: true, status: status)
        }

        return DaemonResponse(requestID: requestID, ok: true, message: raw)
    }

    private func sendLegacyRaw(_ command: String) throws -> String {
        let responseData = try roundTrip(Data(command.utf8))
        return String(decoding: responseData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func execute(_ command: FanCommand) throws {
        let req: DaemonRequest
        switch command {
        case .setMax:
            req = DaemonRequest(command: "max")
        case .setRPM(let rpm):
            req = DaemonRequest(command: "set", rpm: Int(rpm))
        case .resetAuto:
            req = DaemonRequest(command: "auto")
        }
        let response = try send(req)
        if !response.ok {
            let err = response.error ?? DaemonErrorPayload(code: "daemon_error", message: response.message ?? "unknown")
            throw DaemonError.commandFailed(code: err.code, message: err.message)
        }
    }

    public func heartbeat() throws {
        let response = try send(DaemonRequest(command: "heartbeat"))
        if !response.ok {
            let err = response.error ?? DaemonErrorPayload(code: "daemon_error", message: response.message ?? "unknown")
            throw DaemonError.commandFailed(code: err.code, message: err.message)
        }
    }

    private func legacyCommandToRequest(_ command: String) throws -> DaemonRequest {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ")
        guard let first = parts.first.map(String.init) else {
            throw DaemonError.protocolError("empty command")
        }

        switch first {
        case "max", "auto", "status", "heartbeat":
            return DaemonRequest(command: first)
        case "set":
            guard parts.count >= 2, let rpm = Int(parts[1]) else {
                throw DaemonError.protocolError("usage: set <rpm>")
            }
            return DaemonRequest(command: "set", rpm: rpm)
        default:
            return DaemonRequest(command: first)
        }
    }
}

// MARK: - Version two request routing

public final class BackendRequestRouter {
    private let backend: BackendRequestHandling
    public init(backend: BackendRequestHandling) { self.backend = backend }

    public func handle(_ data: Data, peer: AuthenticatedPeer) -> Data {
        let encoder = JSONEncoder()
        if let request = try? JSONDecoder().decode(BackendRequest.self, from: data) {
            return (try? encoder.encode(backend.handle(request, peer: peer))) ?? Data()
        }
        let legacy: DaemonRequest
        if let request = try? DaemonCodec.decodeRequest(data) {
            legacy = request
        } else if data.first == 123 {
            let error = BackendResponse(requestID: "invalid", ok: false,
                error: DaemonErrorPayload(code: "invalid_request", message: "Invalid version two request"))
            return (try? encoder.encode(error)) ?? Data()
        } else {
            let command = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            legacy = DaemonRequest(command: command)
        }
        let response: DaemonResponse
        if legacy.version != 1 {
            response = DaemonResponse(requestID: legacy.requestID, ok: false,
                error: DaemonErrorPayload(code: "unsupported_version", message: "Use protocol version 2"))
        } else if legacy.command == "status" {
            let current = backend.handle(BackendRequest(operation: .status), peer: peer)
            response = DaemonResponse(requestID: legacy.requestID, ok: current.ok,
                message: current.snapshot?.sensors == nil ? "Sensors unavailable" : nil,
                status: current.snapshot?.sensors, error: current.error)
        } else if legacy.command == "auto" || legacy.command == "reset" {
            let current = backend.handle(BackendRequest(operation: .restoreApple), peer: peer)
            response = DaemonResponse(requestID: legacy.requestID, ok: current.ok,
                message: current.snapshot?.restoration == .verified ? "Apple control verified" : "Restoration accepted; verification pending",
                error: current.error)
        } else {
            response = DaemonResponse(requestID: legacy.requestID, ok: false,
                error: DaemonErrorPayload(code: "session_required", message: "Manual control requires a version 2 foreground session"))
        }
        return (try? DaemonCodec.encodeResponse(response)) ?? Data()
    }
}

public final class DaemonServer {
    static let maximumRequestBytes = BackendTiming.maximumFrameBytes
    private let listener: UnixSocketListener
    private let coordinator: BackendCoordinator
    private let observeSystemPower: Bool
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    public init(coordinator: BackendCoordinator, socketPath: String = ThermalForgeDaemon.socketPath,
                authorize: @escaping (AuthenticatedPeer) -> Bool = DaemonServer.isAuthorized,
                observeSystemPower: Bool = true) throws {
        self.coordinator = coordinator
        self.observeSystemPower = observeSystemPower
        let router = BackendRequestRouter(backend: coordinator)
        listener = try UnixSocketListener(path: socketPath, mode: 0o666, authorize: authorize,
                                         handler: router.handle)
    }

    public static func isAuthorized(_ peer: AuthenticatedPeer) -> Bool {
        peer.uid == 0 || peer.uid == currentConsoleUID()
    }

    public func run() {
        withExtendedLifetime(self) {
            start()
            ServiceRunLoop.run()
        }
    }

    public func start() {
        if observeSystemPower { registerPowerNotifications() }
        coordinator.start()
        listener.start()
    }

    public func stop() { listener.stop(); coordinator.stop() }

    private func registerPowerNotifications() {
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notifyPort,
            { refcon, _, message, argument in
                guard let refcon else { return }
                let server = Unmanaged<DaemonServer>.fromOpaque(refcon).takeUnretainedValue()
                switch message {
                case 0xe0000280: // will sleep: invalidate sessions immediately
                    server.coordinator.prepareForSleep()
                    IOAllowPowerChange(server.rootPort, numericCast(Int(bitPattern: argument)))
                case 0xe0000270:
                    IOAllowPowerChange(server.rootPort, numericCast(Int(bitPattern: argument)))
                case 0xe0000300:
                    server.coordinator.resumeAfterWake()
                default: break
                }
            }, &notifier)
        if rootPort != 0, let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
        }
    }

    deinit {
        listener.stop()
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
    }
}

private func currentConsoleUID() -> uid_t? {
    var st = stat()
    guard stat("/dev/console", &st) == 0, st.st_uid != 0 else { return nil }
    return st.st_uid
}
