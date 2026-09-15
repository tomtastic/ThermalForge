import ArgumentParser
import Darwin
import Foundation
import ThermalForgeCore

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install",
        abstract: "Install the protected backend and independent recovery (requires sudo)")
    func run() throws {
        guard geteuid() == 0 else { throw ValidationError("Run with sudo: sudo thermalforge install") }
        let transaction = try ServiceInstallationLock()
        defer { withExtendedLifetime(transaction) {} }
        try InstalledServiceManager().coordinator().install()
        print("Backend and independent recovery installed.")
    }
}

/// No system service is replaced by automated tests; ordering is tested through
/// ServiceInstallationCoordinator with injected side effects.
struct InstalledServiceManager {
    let launchd = LaunchdCoordinator()
    let processes = SystemRecoveryProcessControl()
    let fm = FileManager.default

    func coordinator(removeFiles: @escaping () throws -> Void = {}) -> ServiceInstallationCoordinator {
        ServiceInstallationCoordinator(stopControllers: stopControllers, restore: verifyHandback,
            stopRecovery: stopRecovery,
            stageFiles: stageFiles, startRecovery: startRecovery, startBackend: startBackend,
            removeFiles: removeFiles)
    }

    func stopControllers() throws {
        try stopService(ThermalForgeDaemon.label)
        try fenceDiscoveredProcesses(recoveryOnly: false)
    }

    func stopRecovery() throws {
        try stopService(ThermalForgeDaemon.recoveryLabel)
        // A job may spawn between its PID query and bootout. Once unloaded it
        // cannot respawn; fence any remaining recovery process before SMC work.
        try fenceDiscoveredProcesses(recoveryOnly: true)
    }

    func fenceDiscoveredProcesses(recoveryOnly: Bool) throws {
        // Fence old foreground writers and the old GUI before touching SMC.
        // The process name is only discovery; each signal is bound to a start identity.
        let result = try ProcessRunner().run(executableURL: URL(fileURLWithPath: "/bin/ps"),
                                             arguments: ["-axo", "pid=,comm=,args="])
        guard result.succeeded else { throw ValidationError("Cannot enumerate legacy controllers") }
        var identities: [BackendProcessIdentity] = []
        for line in result.standardOutput.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count >= 2, let pid = Int32(fields[0]), pid != getpid() else { continue }
            let name = URL(fileURLWithPath: String(fields[1])).lastPathComponent
            guard name == "ThermalForgeApp" || name == "thermalforge" else { continue }
            let arguments = fields.count > 2 ? String(fields[2]) : ""
            let words = arguments.split(whereSeparator: \.isWhitespace)
            let isRecovery = name == "thermalforge" && words.contains("recovery")
            guard isRecovery == recoveryOnly else { continue }
            if name == "thermalforge" {
                // Do not stop another installer.
                guard !words.contains("install"), !words.contains("uninstall") else { continue }
            }
            guard let identity = processes.identity(pid: pid) else {
                if kill(pid, 0) == -1 && errno == ESRCH { continue }
                throw ValidationError("Cannot identify legacy controller \(pid)")
            }
            identities.append(identity)
        }
        for identity in identities { try fence(identity) }
    }

    func stopService(_ label: String) throws {
        guard case .loaded(let pid) = try launchd.serviceState(label: label) else { return }
        let identity: BackendProcessIdentity?
        if let pid {
            identity = processes.identity(pid: pid)
            guard identity != nil || (kill(pid, 0) == -1 && errno == ESRCH) else {
                throw ValidationError("Cannot authenticate \(label) process before stopping it")
            }
        } else { identity = nil }
        try launchd.bootout(label: label)
        if let identity { try fence(identity) }
        guard case .notLoaded = try launchd.serviceState(label: label) else {
            throw ValidationError("\(label) remains loaded")
        }
    }

    func fence(_ identity: BackendProcessIdentity) throws {
        try processes.terminate(identity, force: false)
        let start = BackendTiming.monotonicNow
        while processes.state(of: identity) != .exited {
            let elapsed = BackendTiming.monotonicNow - start
            if elapsed >= 1 { try processes.terminate(identity, force: true) }
            if elapsed >= 4 { throw ValidationError("Controller \(identity.pid) has not exited; control remains blocked") }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func verifyHandback() throws -> RestorationResult {
        if case .loaded = try launchd.serviceState(label: ThermalForgeDaemon.recoveryLabel) {
            let deadline = BackendTiming.monotonicNow + 15
            var last = RestorationResult(verified: false, errors: ["Recovery unavailable"])
            var receivedSnapshot = false
            repeat {
                do {
                    let status = try RecoveryClient.inspect()
                    receivedSnapshot = true
                    last = status.restoration
                    if status.readyForInstallation { return last }
                } catch {
                    if !receivedSnapshot { last.errors = [String(describing: error)] }
                }
                Thread.sleep(forTimeInterval: 0.1)
            } while BackendTiming.monotonicNow < deadline
            if !receivedSnapshot {
                return RecoveryServiceRepair(stop: stopRecovery, makeCoordinator: {
                    let store = try FileRecoveryMarkerStore(directory: RecoveryService.stateDirectory)
                    let fanControl = try FanControl()
                    return try RecoveryCoordinator(markerStore: store, processControl: processes,
                        restore: { fanControl.restoreApple() })
                }, restart: {
                    if case .notLoaded = try launchd.serviceState(label: ThermalForgeDaemon.recoveryLabel) {
                        try launchd.bootstrap(plistPath: ThermalForgeDaemon.recoveryPlistPath)
                    }
                }).restore()
            }
            return .init(verified: false, errors: last.errors + ["Independent recovery has not confirmed handback"])
        }
        // Upgrade from v1: all old writers have positively exited and there is
        // no recovery writer. Verify directly before installing either service.
        return try FanControl().restoreApple()
    }

    func stageFiles() throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardizedFileURL
        guard fm.isExecutableFile(atPath: source.path) else { throw ValidationError("Installer executable is missing") }
        let directory = URL(fileURLWithPath: ThermalForgeDaemon.installPath).deletingLastPathComponent()
        try secureDirectory(directory)
        try secureDirectory(URL(fileURLWithPath: ThermalForgeDaemon.stateDirectory))
        let target = URL(fileURLWithPath: ThermalForgeDaemon.installPath)
        var targetInfo = stat()
        if lstat(target.path, &targetInfo) == 0, targetInfo.st_mode & S_IFMT != S_IFREG {
            throw ValidationError("Canonical service executable must be a regular file")
        }
        if source.resolvingSymlinksInPath() != target.resolvingSymlinksInPath() {
            let staging = directory.appendingPathComponent("thermalforge-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: source, to: staging)
            try protect(staging.path, mode: 0o755)
            guard rename(staging.path, target.path) == 0 else { throw ValidationError("Cannot atomically install protected executable") }
        }
        try protect(target.path, mode: 0o755)
        try fm.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
        let link = ThermalForgeDaemon.cliPath
        var info = stat()
        if lstat(link, &info) == 0 { try fm.removeItem(atPath: link) }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target.path)
        try writePlist(label: ThermalForgeDaemon.recoveryLabel, command: "recovery", path: ThermalForgeDaemon.recoveryPlistPath)
        try writePlist(label: ThermalForgeDaemon.label, command: "daemon", path: ThermalForgeDaemon.plistPath)
    }

    func secureDirectory(_ path: URL) throws {
        var info = stat()
        if lstat(path.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR {
            throw ValidationError("Protected installation path is not a directory: \(path.path)")
        }
        try fm.createDirectory(at: path, withIntermediateDirectories: true)
        try protect(path.path, mode: 0o755)
    }

    func protect(_ path: String, mode: mode_t) throws {
        guard chown(path, 0, 0) == 0, chmod(path, mode) == 0 else {
            throw ValidationError("Cannot protect \(path)")
        }
    }

    func writePlist(label: String, command: String, path: String) throws {
        let plist: [String: Any] = ["Label": label,
            "ProgramArguments": [ThermalForgeDaemon.installPath, command],
            "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Background",
            "ThrottleInterval": 2, "ExitTimeOut": 2, "Umask": 0o022]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try protect(path, mode: 0o644)
    }

    func startRecovery() throws {
        try launchd.bootstrap(plistPath: ThermalForgeDaemon.recoveryPlistPath)
        let deadline = BackendTiming.monotonicNow + 15
        var last = "No recovery response"
        repeat {
            do {
                let state = try RecoveryClient.inspect()
                if state.readyForInstallation { return }
                last = "Recovery pending: " + state.restoration.errors.joined(separator: "; ")
                if state.generation != nil { last += "; a backend generation is still registered" }
            } catch { last = "Recovery socket: \(error)" }
            Thread.sleep(forTimeInterval: 0.1)
        } while BackendTiming.monotonicNow < deadline
        if let state = try? launchd.serviceState(label: ThermalForgeDaemon.recoveryLabel) {
            last += "; launchd state: \(state)"
        }
        throw ServiceInstallationError.serviceUnavailable(ThermalForgeDaemon.recoveryLabel, detail: last)
    }

    func startBackend() throws {
        try launchd.bootstrap(plistPath: ThermalForgeDaemon.plistPath)
        let deadline = BackendTiming.monotonicNow + 10
        let request = try JSONEncoder().encode(BackendRequest(operation: .status))
        repeat {
            if let data = try? UnixSocketTransport.roundTrip(request, path: ThermalForgeDaemon.socketPath),
               let response = try? JSONDecoder().decode(BackendResponse.self, from: data), response.ok { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while BackendTiming.monotonicNow < deadline
        throw ServiceInstallationError.serviceUnavailable(ThermalForgeDaemon.label)
    }
}
