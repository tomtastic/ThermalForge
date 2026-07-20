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
    public static let installPath = "/usr/local/bin/thermalforge"
    public static let label = "com.thermalforge.daemon"

    /// Check if the daemon socket exists and accepts connections.
    public static var isRunning: Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, socketPath)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
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

    public init(socketPath: String = ThermalForgeDaemon.socketPath, timeoutSeconds: Int = 5) {
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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.connectionFailed }
        defer { close(fd) }
        configureClientSocket(fd)

        // Bound send/recv so a stuck daemon can't block the caller forever.
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, socketPath)

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw DaemonError.notRunning }

        let payload = try DaemonCodec.encodeRequest(request)
        let bytes = [UInt8](payload + [0x0A])
        let written = bytes.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress!, buf.count)
        }
        guard written >= 0 else { throw DaemonError.connectionFailed }

        // Read response — 64KB handles status JSON on sensor-rich machines
        let responseData = try readResponse(fd)
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

    private func shouldRetryLegacy(error: DaemonError, for request: DaemonRequest) -> Bool {
        guard legacyCommand(for: request) != nil else { return false }
        switch error {
        case .commandFailed(let code, let message):
            return code == "legacy_error" && message.contains("unknown command")
        case .timedOut:
            return true
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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.connectionFailed }
        defer { close(fd) }
        configureClientSocket(fd)

        // Bound send/recv so a stuck daemon can't block the caller forever.
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, socketPath)

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw DaemonError.notRunning }

        let cmdData = Array((command + "\n").utf8)
        let written = cmdData.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress!, buf.count)
        }
        guard written >= 0 else { throw DaemonError.connectionFailed }

        let responseData = try readResponse(fd)
        return String(decoding: responseData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func configureClientSocket(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        withUnsafePointer(to: &noSigPipe) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ptr, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    private func readResponse(_ fd: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count - 1)
        if n > 0 {
            return Data(buffer[0..<n])
        }

        if n == 0 {
            throw DaemonError.connectionFailed
        }

        if errno == EAGAIN || errno == EWOULDBLOCK {
            throw DaemonError.timedOut
        }
        throw DaemonError.connectionFailed
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

    public func fetchRules() throws -> [ThermalRule] {
        let response = try send(DaemonRequest(command: "rules.list"))
        if !response.ok {
            let err = response.error ?? DaemonErrorPayload(code: "daemon_error", message: response.message ?? "unknown")
            throw DaemonError.commandFailed(code: err.code, message: err.message)
        }
        return response.rules ?? []
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

// MARK: - Daemon Server

enum HeartbeatWatchdog {
    static let timeout: TimeInterval = 10

    static func shouldReset(
        lastHeartbeat: Date?,
        hasManualControl: Bool,
        now: Date = Date()
    ) -> Bool {
        guard let lastHeartbeat, hasManualControl else { return false }
        return now.timeIntervalSince(lastHeartbeat) > timeout
    }
}

public final class DaemonServer {
    private let socketFD: Int32
    private let fanControl: FanControl

    /// Serializes all SMC access — prevents data race between client handler and watchdog.
    private let smcLock = NSLock()
    /// Manual-control state, shared by requests, wake handling, and the watchdog.
    private let controlStateLock = NSLock()
    /// Last fan command — re-applied after sleep/wake.
    private var lastCommand: FanCommand?
    /// Heartbeat: last time the app checked in.
    private var lastHeartbeat: Date?
    private let authorizedUID: uid_t?

    public init(fanControl: FanControl) throws {
        self.fanControl = fanControl
        self.authorizedUID = currentConsoleUID()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ThermalForgeError.smcConnectionFailed
        }
        self.socketFD = fd

        unlink(ThermalForgeDaemon.socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, ThermalForgeDaemon.socketPath)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ThermalForgeError.writeFailed("bind() failed: \(errno)")
        }

        if let uid = authorizedUID {
            _ = chown(ThermalForgeDaemon.socketPath, uid, 0)
            chmod(ThermalForgeDaemon.socketPath, 0o600)
        } else {
            chmod(ThermalForgeDaemon.socketPath, 0o600)
        }

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw ThermalForgeError.writeFailed("listen() failed")
        }
    }

    /// Run the server loop (blocks forever).
    public func run() {
        NSLog("ThermalForge daemon: listening on %@", ThermalForgeDaemon.socketPath)

        registerWakeNotification()
        startHeartbeatWatchdog()

        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                // Drain per-iteration temporaries — this block never returns, so
                // without an explicit pool every autoreleased object accumulates
                // for the daemon's lifetime (multi-GB leak over days).
                autoreleasepool {
                    let clientFD = accept(socketFD, nil, nil)
                    guard clientFD >= 0 else { return }
                    handleClient(clientFD)
                    close(clientFD)
                }
            }
        }

        RunLoop.main.run()
    }

    // MARK: - Heartbeat Watchdog

    private func startHeartbeatWatchdog() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                autoreleasepool {
                    Thread.sleep(forTimeInterval: 2)

                    let snapshot = controlStateSnapshot()

                    // Only reset if: app has connected before (lastBeat != nil),
                    // fans are in manual mode, and heartbeat is stale
                    if HeartbeatWatchdog.shouldReset(
                        lastHeartbeat: snapshot.heartbeat,
                        hasManualControl: snapshot.command != nil
                    ) {
                        NSLog("ThermalForge daemon: heartbeat stale — resetting fans to auto")
                        smcLock.lock()
                        defer { smcLock.unlock() }

                        // A fresh request may have arrived while the watchdog was
                        // waiting for SMC access. Recheck before overriding it.
                        let current = controlStateSnapshot()
                        guard HeartbeatWatchdog.shouldReset(
                            lastHeartbeat: current.heartbeat,
                            hasManualControl: current.command != nil
                        ) else { return }

                        let resetSucceeded: Bool
                        do {
                            try fanControl.resetAuto()
                            resetSucceeded = true
                        } catch {
                            NSLog("ThermalForge daemon: watchdog reset failed: %@, will retry", "\(error)")
                            resetSucceeded = false
                        }

                        // Only clear state if reset actually worked — otherwise retry next cycle
                        if resetSucceeded {
                            clearControlState()
                        }
                    }
                }
            }
        }
    }

    private func controlStateSnapshot() -> (command: FanCommand?, heartbeat: Date?) {
        controlStateLock.lock()
        defer { controlStateLock.unlock() }
        return (lastCommand, lastHeartbeat)
    }

    private func recordManualControl(_ command: FanCommand) {
        controlStateLock.lock()
        lastCommand = command
        lastHeartbeat = Date()
        controlStateLock.unlock()
    }

    private func recordHeartbeat() {
        controlStateLock.lock()
        lastHeartbeat = Date()
        controlStateLock.unlock()
    }

    private func clearControlState() {
        controlStateLock.lock()
        lastCommand = nil
        lastHeartbeat = nil
        controlStateLock.unlock()
    }

    // MARK: - Sleep/Wake

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    private func registerWakeNotification() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            refcon, &notifyPort, { (refcon, _, messageType, messageArgument) in
                guard let refcon = refcon else { return }
                let server = Unmanaged<DaemonServer>.fromOpaque(refcon).takeUnretainedValue()

                let kSystemHasPoweredOn: UInt32 = 0xe0000300
                let kSystemWillSleep: UInt32 = 0xe0000280
                let kCanSystemSleep: UInt32 = 0xe0000270

                switch messageType {
                case kSystemHasPoweredOn:
                    server.handleWake()
                case kSystemWillSleep, kCanSystemSleep:
                    IOAllowPowerChange(server.rootPort, numericCast(Int(bitPattern: messageArgument)))
                default:
                    break
                }
            }, &notifier
        )

        guard rootPort != 0, let notifyPort = notifyPort else {
            NSLog("ThermalForge daemon: failed to register for power notifications")
            return
        }

        let source = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        NSLog("ThermalForge daemon: registered for wake notifications")
    }

    private func handleWake() {
        guard controlStateSnapshot().command != nil else {
            NSLog("ThermalForge daemon: woke — no profile to re-apply")
            return
        }

        NSLog("ThermalForge daemon: woke — re-applying previous fan command")

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [self] in
            smcLock.lock()
            defer { smcLock.unlock() }
            guard let command = controlStateSnapshot().command else {
                NSLog("ThermalForge daemon: wake re-apply cancelled — fan control returned to auto")
                return
            }
            do {
                switch command {
                case .setMax:
                    try fanControl.setMax()
                case .setRPM(let rpm):
                    try fanControl.setAllFans(rpm: rpm)
                case .resetAuto:
                    try fanControl.resetAuto()
                }
                NSLog("ThermalForge daemon: re-applied after wake")
            } catch {
                NSLog("ThermalForge daemon: wake re-apply failed: %@", "\(error)")
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        guard isAuthorizedClient(fd) else {
            TFLogger.shared.event(ThermalEvent(type: .daemonCommandRejected, details: "unauthorized client"))
            writeResponse(fd, fallbackText: "error: unauthorized client")
            return
        }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count - 1)
        guard n > 0 else { return }

        let bytes = Data(buffer[0..<n])
        let request = decodeRequest(bytes)

        let response: DaemonResponse = {
            smcLock.lock()
            defer { smcLock.unlock() }
            return handleRequest(request)
        }()

        writeResponse(fd, typed: response, fallbackText: response.ok ? "ok" : "error: \(response.error?.message ?? "unknown")")
    }

    private func decodeRequest(_ data: Data) -> DaemonRequest {
        if let req = try? DaemonCodec.decodeRequest(data) {
            return req
        }

        let plain = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = plain.split(separator: " ")
        guard let first = parts.first.map(String.init) else {
            return DaemonRequest(command: "invalid")
        }

        if first == "set", parts.count >= 2, let rpm = Int(parts[1]) {
            return DaemonRequest(command: "set", rpm: rpm)
        }
        return DaemonRequest(command: first)
    }

    private func handleRequest(_ request: DaemonRequest) -> DaemonResponse {
        switch request.command {
        case "max":
            return withErrorBoundary(requestID: request.requestID) {
                try fanControl.setMax()
                recordManualControl(.setMax)
                return DaemonResponse(requestID: request.requestID, ok: true, message: "ok")
            }

        case "auto":
            return withErrorBoundary(requestID: request.requestID) {
                try fanControl.resetAuto()
                clearControlState()
                return DaemonResponse(requestID: request.requestID, ok: true, message: "ok")
            }

        case "set":
            guard let rpm = request.rpm else {
                return DaemonResponse(
                    requestID: request.requestID,
                    ok: false,
                    error: DaemonErrorPayload(code: "validation_error", message: "usage: set <rpm>")
                )
            }
            return withErrorBoundary(requestID: request.requestID) {
                try fanControl.setAllFans(rpm: Float(rpm))
                recordManualControl(.setRPM(Float(rpm)))
                return DaemonResponse(requestID: request.requestID, ok: true, message: "ok")
            }

        case "status":
            return withErrorBoundary(requestID: request.requestID) {
                let status = try fanControl.status()
                return DaemonResponse(requestID: request.requestID, ok: true, status: status)
            }

        case "heartbeat":
            recordHeartbeat()
            return DaemonResponse(requestID: request.requestID, ok: true, message: "ok")

        case "rules.list":
            return DaemonResponse(requestID: request.requestID, ok: true, rules: RulePersistence.load())

        case "rules.put":
            guard let rule = request.rule else {
                return DaemonResponse(requestID: request.requestID, ok: false, error: DaemonErrorPayload(code: "validation_error", message: "missing rule payload"))
            }
            var rules = RulePersistence.load()
            if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[idx] = rule
            } else {
                rules.append(rule)
            }
            do {
                try RulePersistence.save(rules)
                return DaemonResponse(requestID: request.requestID, ok: true, rules: rules)
            } catch {
                TFLogger.shared.event(ThermalEvent(type: .daemonCommandFailed, details: "rules.put failed: \(error)"))
                return DaemonResponse(requestID: request.requestID, ok: false, error: DaemonErrorPayload(code: "persist_failed", message: "\(error)"))
            }

        case "rules.remove":
            guard let ruleID = request.ruleID else {
                return DaemonResponse(requestID: request.requestID, ok: false, error: DaemonErrorPayload(code: "validation_error", message: "missing ruleID"))
            }
            var rules = RulePersistence.load()
            rules.removeAll(where: { $0.id == ruleID })
            do {
                try RulePersistence.save(rules)
                return DaemonResponse(requestID: request.requestID, ok: true, rules: rules)
            } catch {
                TFLogger.shared.event(ThermalEvent(type: .daemonCommandFailed, details: "rules.remove failed: \(error)"))
                return DaemonResponse(requestID: request.requestID, ok: false, error: DaemonErrorPayload(code: "persist_failed", message: "\(error)"))
            }

        case "rules.enable", "rules.disable":
            guard let ruleID = request.ruleID else {
                return DaemonResponse(requestID: request.requestID, ok: false, error: DaemonErrorPayload(code: "validation_error", message: "missing ruleID"))
            }
            let desired = request.command == "rules.enable"
            var rules = RulePersistence.load()
            if let idx = rules.firstIndex(where: { $0.id == ruleID }) {
                rules[idx].enabled = desired
            }
            do {
                try RulePersistence.save(rules)
                return DaemonResponse(requestID: request.requestID, ok: true, rules: rules)
            } catch {
                TFLogger.shared.event(ThermalEvent(type: .daemonCommandFailed, details: "\(request.command) failed: \(error)"))
                return DaemonResponse(requestID: request.requestID, ok: false, error: DaemonErrorPayload(code: "persist_failed", message: "\(error)"))
            }

        default:
            TFLogger.shared.event(ThermalEvent(type: .daemonCommandRejected, details: "unknown command: \(request.command)"))
            return DaemonResponse(
                requestID: request.requestID,
                ok: false,
                error: DaemonErrorPayload(code: "unknown_command", message: "unknown command '\(request.command)'")
            )
        }
    }

    private func withErrorBoundary(requestID: String, _ body: () throws -> DaemonResponse) -> DaemonResponse {
        do {
            return try body()
        } catch {
            TFLogger.shared.event(ThermalEvent(type: .daemonCommandFailed, details: "request failed: \(error)"))
            return DaemonResponse(
                requestID: requestID,
                ok: false,
                error: DaemonErrorPayload(code: "command_failed", message: "\(error)")
            )
        }
    }

    private func writeResponse(_ fd: Int32, typed: DaemonResponse? = nil, fallbackText: String) {
        if let typed, let data = try? DaemonCodec.encodeResponse(typed) {
            let bytes = [UInt8](data)
            _ = bytes.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress!, buf.count)
            }
            return
        }

        let responseBytes = Array((fallbackText + "\n").utf8)
        _ = responseBytes.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress!, buf.count)
        }
    }

    private func isAuthorizedClient(_ fd: Int32) -> Bool {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0 else {
            return false
        }

        if peerUID == 0 { return true }
        guard let authorizedUID else { return false }
        return peerUID == authorizedUID
    }

    deinit {
        close(socketFD)
        unlink(ThermalForgeDaemon.socketPath)
    }
}

// MARK: - Helpers

private func currentConsoleUID() -> uid_t? {
    var st = stat()
    guard stat("/dev/console", &st) == 0 else { return nil }
    guard st.st_uid != 0 else { return nil }
    return st.st_uid
}

/// Copy a path string into sockaddr_un.sun_path.
private func setPath(_ addr: inout sockaddr_un, _ path: String) {
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
            _ = strlcpy(dest, path, 104)
        }
    }
}
