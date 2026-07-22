//
//  ThermalForge.swift
//  ThermalForge
//
//  CLI entry point — fan control for Apple Silicon MacBooks.
//

import ArgumentParser
import Foundation
import ThermalForgeCore

@main
struct ThermalForge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thermalforge",
        abstract: "Fan control for Apple Silicon MacBooks",
        version: ThermalForgeVersion.current,
        subcommands: [
            Max.self,
            Auto.self,
            SetSpeed.self,
            Status.self,
            Discover.self,
            Watch.self,
            Calibrate.self,
            Log.self,
            Rules.self,
            Install.self,
            Uninstall.self,
            Daemon.self,
        ]
    )
}

// MARK: - Watch

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Monitor temps and auto-adjust fans based on a profile"
    )

    @Option(name: .shortAndLong, help: "Profile: silent, balanced, performance, max, smart")
    var profile: String = "balanced"

    @Option(name: .shortAndLong, help: "Active poll interval in seconds (default 1.0; relaxes to 2s when idle)")
    var interval: Double = 1.0

    @Flag(name: .long, help: "Output JSON on each update")
    var json: Bool = false

    func run() throws {
        let profiles = FanProfile.builtIn
        guard let selectedProfile = profiles.first(where: { $0.id == profile }) else {
            throw ValidationError(
                "Unknown profile '\(profile)'. Options: \(profiles.map(\.id).joined(separator: ", "))"
            )
        }

        let fc = try FanControl()
        let monitor = ThermalMonitor(fanControl: fc, profile: selectedProfile)

        print("ThermalForge watch — profile: \(selectedProfile.name)")
        print("Hardware: \(fc.hardwareInfo)")
        print("Polling every \(interval)s. Ctrl-C to stop.\n")

        // CLI runs as root, so fan commands go directly through FanControl
        monitor.onFanCommand = { command in
            switch command {
            case .setMax: try fc.setMax()
            case .setRPM(let rpm): try fc.setAllFans(rpm: rpm)
            case .resetAuto: try fc.resetAuto()
            }
        }

        monitor.onUpdate = { [json] status, activeProfile, state, _ in
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.keyEncodingStrategy = .convertToSnakeCase
                if let data = try? encoder.encode(status),
                   let line = String(data: data, encoding: .utf8)
                {
                    print(line)
                }
            } else {
                let temperatures = TemperatureSummary(status.temperatures)
                let cpuTemp = temperatures.cpu ?? 0
                let gpuTemp = temperatures.gpu ?? 0
                let fan0 = status.fans.first.map { $0.actualRPM } ?? 0
                let stateLabel: String
                switch state {
                case .idle: stateLabel = "idle"
                case .active(let name): stateLabel = name
                case .safetyOverride: stateLabel = "SAFETY"
                }
                let timestamp = ISO8601DateFormatter().string(from: Date())
                print("[\(timestamp)] CPU: \(String(format: "%.0f", cpuTemp))°C  GPU: \(String(format: "%.0f", gpuTemp))°C  Fan: \(fan0) RPM  [\(stateLabel)]")
            }
        }

        let cancellationToken = CancellationToken()
        let interruptSource = InterruptSignalSource {
            if cancellationToken.cancel() {
                print("\nStopping monitor...")
                DispatchQueue.main.async {
                    CFRunLoopStop(CFRunLoopGetMain())
                }
            }
        }
        defer { interruptSource.cancel() }

        monitor.start(interval: interval)

        while !cancellationToken.isCancelled {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }

        monitor.stopAndWait()
        print("Resetting fans to auto...")
        do {
            try fc.resetAuto()
            print("Fans reset to Apple defaults.")
        } catch {
            print("Warning: unable to reset fans: \(error)")
        }
        throw ExitCode(130)
    }
}

// MARK: - Calibrate

struct Calibrate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "Measure this machine's thermal characteristics for the Smart profile"
    )

    @Option(name: .shortAndLong, help: "Calibration mode: quick, standard, optimized (increasing convergence strictness)")
    var mode: String = "standard"

    @Option(name: .shortAndLong, help: "Stress type: combined (CPU+GPU, default), cpu, gpu")
    var stress: String = "combined"

    @Option(name: .long, help: "Reuse a known-safe workload intensity and skip Phase 1 (0.001-0.5)")
    var intensity: Float?

    @Flag(name: .long, help: "Ignore a saved workload intensity and run Phase 1 again")
    var rediscoverIntensity: Bool = false

    @Flag(name: .long, help: "Clear calibration data and start fresh")
    var reset: Bool = false

    func run() throws {
        if reset {
            guard geteuid() == 0 else {
                throw ValidationError(
                    "Run with sudo to clear both root and console-user data: " +
                    "sudo thermalforge calibrate --reset"
                )
            }
            let removedPaths = try CalibrationData.clearAllStoredCalibration()
            if !removedPaths.isEmpty {
                print("Calibration data cleared (all lid states). Smart will use the default curve.")
                for path in removedPaths {
                    print("  \(path.path)")
                }
                TFLogger.shared.calibration("Calibration data reset by user")
            } else {
                print("No calibration data to clear.")
            }
            return
        }

        guard geteuid() == 0 else {
            throw ValidationError("Run with sudo: sudo thermalforge calibrate")
        }

        guard let calMode = CalibrationMode(rawValue: mode) else {
            throw ValidationError("Unknown mode '\(mode)'. Options: quick, standard, optimized")
        }

        guard let calStress = CalibrationStressType(rawValue: stress) else {
            throw ValidationError("Unknown stress type '\(stress)'. Options: combined, cpu, gpu")
        }

        if let intensity, !(0.001 ... 0.5).contains(intensity) {
            throw ValidationError("Intensity must be between 0.001 and 0.5")
        }
        if intensity != nil && rediscoverIntensity {
            throw ValidationError("Use either --intensity or --rediscover-intensity, not both")
        }

        // Prevent downgrade
        if CalibrationRunner.wouldDowngrade(mode: calMode) {
            let existing = CalibrationData.load()
            let existingMode = existing?.mode ?? "unknown"
            throw ValidationError(
                "Existing calibration was run at '\(existingMode)' level. " +
                "Running '\(mode)' would downgrade your data. " +
                "Use --mode \(existingMode) or higher."
            )
        }

        // Stop the daemon and menu bar app while calibration has direct fan
        // control, then restore the daemon on every exit path.
        let lifecycle = CalibrationSystemLifecycle()
        try lifecycle.withPausedServices(onEvent: { event in
            switch event {
            case let .daemonStopped(pid):
                if let pid {
                    print("Stopping ThermalForge daemon (PID \(pid)) — will resume after calibration...")
                } else {
                    print("Stopping ThermalForge daemon — will resume after calibration...")
                }
                Thread.sleep(forTimeInterval: 1)
            case .daemonResuming:
                print("Resuming ThermalForge daemon...")
            }
        }) {
            let fc = try FanControl()
            let currentAmbient = (try? fc.status()).flatMap {
                TemperatureSummary($0.temperatures).ambient
            }

            let existingCalibration = CalibrationData.load()
            let reusableIntensity: Float?
            if intensity == nil,
               !rediscoverIntensity,
               existingCalibration?.isValid == true,
               existingCalibration?.stressType == calStress.rawValue,
               let previous = existingCalibration?.workloadIntensity,
               (0.001 ... 0.5).contains(previous),
               let previousAmbient = existingCalibration?.ambientTemperature,
               let currentAmbient,
               abs(previousAmbient - currentAmbient) <= 3
            {
                reusableIntensity = previous
            } else {
                reusableIntensity = nil
            }
            let selectedIntensity = intensity ?? reusableIntensity

            print("ThermalForge Calibration")
            print("========================")
            print("Mode: \(calMode.description)")
            print("Stress: \(calStress.description)")
            if let selectedIntensity {
                let source = intensity == nil ? "saved calibration" : "command line"
                print("Workload: \(String(format: "%.5f", selectedIntensity)) (reused from \(source); Phase 1 skipped)")
            } else if rediscoverIntensity {
                print("Workload: rediscovering intensity (saved value ignored)")
            }
            print("")
            print("This will stress your \(calStress == .combined ? "CPU and GPU" : calStress == .cpu ? "CPU" : "GPU") and measure thermal response at 5 fan speed levels.")
            print("Fans will be loud during the test.")
            print("")
            print("DISCLAIMER: Calibration pushes your Mac to full load and cycles fan speeds.")
            print("This is within normal operating parameters but ThermalForge is provided")
            print("as-is with no warranty. Use at your own risk.")
            print("")
            print("Press Ctrl-C at any time to stop. Fans will reset to Apple defaults.\n")

            let cancellationToken = CancellationToken()
            let runner = CalibrationRunner(
                fanControl: fc,
                mode: calMode,
                stressType: calStress,
                workloadIntensity: selectedIntensity,
                cancellationToken: cancellationToken
            )

            let interruptSource = InterruptSignalSource {
                if cancellationToken.cancel() {
                    print("\n\nCalibration interruption requested; cleaning up...")
                }
            }
            defer { interruptSource.cancel() }

            runner.onProgress = { message in
                print(message)
            }

            do {
                let data = try runner.run()
                if cancellationToken.isCancelled {
                    if let logPath = runner.logPath {
                        try? FileManager.default.removeItem(at: logPath)
                    }
                    throw CalibrationError.cancelled
                }
                let savedPaths = try data.save()

                print("\nCalibration complete.")
                print("\nSaved to:")
                for path in savedPaths {
                    print("  \(path.path)")
                }
                if let logPath = runner.logPath {
                    print("  \(logPath.path)")
                }
                print("\nResults:")
                for m in data.measurements {
                    print("  \(Int(m.targetTemp))°C → \(Int(m.holdingRPMPercent * 100))% fan speed")
                }
                print("\nThe Smart profile will now use these measurements for this machine.")
                if runner.logPath != nil {
                    print("The CSV log contains every sensor reading taken during calibration.")
                }
            } catch CalibrationError.cancelled {
                if let logPath = runner.logPath {
                    try? FileManager.default.removeItem(at: logPath)
                }
                print("Fans reset to Apple defaults. No calibration data was saved.")
                throw ExitCode(130)
            } catch {
                throw ValidationError("Calibration failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Log

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Record thermal data to CSV for research and analysis"
    )

    @Option(name: .shortAndLong, help: "Sample rate in Hz (default: 1)")
    var rate: Double = 1.0

    @Option(name: .shortAndLong, help: "Duration (e.g., 1h, 30m, 60s). Omit for indefinite.")
    var duration: String?

    @Option(name: .shortAndLong, help: "Output directory (default: ~/Library/Application Support/ThermalForge/logs)")
    var output: String?

    @Flag(name: .long, help: "Keep logs permanently (default: auto-delete after 24h)")
    var noExpire: Bool = false

    func run() throws {
        let fc = try FanControl()

        let durationSec: TimeInterval? = duration.flatMap { parseDuration($0) }
        let outputURL = output.map { URL(fileURLWithPath: $0) }
        let cancellationToken = CancellationToken()

        let logger = try ThermalLogger(
            fanControl: fc,
            rateHz: rate,
            duration: durationSec,
            outputDir: outputURL,
            noExpire: noExpire,
            cancellationToken: cancellationToken
        )

        // Clean expired sessions on startup
        ThermalLogger.cleanExpired()

        let durationStr = durationSec.map { formatDuration($0) } ?? "indefinite"
        print("ThermalForge Log")
        print("  Rate: \(rate) Hz")
        print("  Duration: \(durationStr)")
        print("  Output: \(logger.outputPath.path)")
        print("  Auto-delete: \(noExpire ? "off" : "after 24h")")
        print("\nLogging... Ctrl-C to stop.\n")

        let interruptSource = InterruptSignalSource {
            if cancellationToken.cancel() {
                print("\n\nStopping and finalizing log...")
            }
        }
        defer { interruptSource.cancel() }

        logger.onSample = { line in
            print(line)
        }

        try logger.run()

        print("\nLog saved to: \(logger.outputPath.path)")
        print("  thermal.csv   — sensor readings + fan state")
        print("  processes.csv — top processes by CPU")
        print("  metadata.json — session info + data dictionary")

        if cancellationToken.isCancelled {
            throw ExitCode(130)
        }
    }

    private func parseDuration(_ s: String) -> TimeInterval? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("h"), let v = Double(trimmed.dropLast()) { return v * 3600 }
        if trimmed.hasSuffix("m"), let v = Double(trimmed.dropLast()) { return v * 60 }
        if trimmed.hasSuffix("s"), let v = Double(trimmed.dropLast()) { return v }
        return Double(trimmed)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        if t >= 3600 { return "\(Int(t / 3600))h" }
        if t >= 60 { return "\(Int(t / 60))m" }
        return "\(Int(t))s"
    }
}

// MARK: - Rules

struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Manage IF/THEN/ELSE thermal rules",
        subcommands: [
            RulesList.self,
            RulesAdd.self,
            RulesRemove.self,
            RulesEnable.self,
            RulesDisable.self,
            RulesTest.self,
        ]
    )
}

struct RulesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all persisted rules"
    )

    func run() throws {
        let rules = RulePersistence.load().sorted { lhs, rhs in
            if lhs.priority == rhs.priority { return lhs.name < rhs.name }
            return lhs.priority > rhs.priority
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        print(String(data: data, encoding: .utf8) ?? "[]")
    }
}

struct RulesAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a rule (example: IF temp >= 55 THEN max until <= 65)"
    )

    @Option(name: .shortAndLong, help: "Rule name")
    var name: String = "IF temp >= 55 THEN max until <= 65"

    @Option(name: .shortAndLong, help: "Trigger threshold in Celsius")
    var trigger: Float = 55

    @Option(name: .long, help: "Latch release threshold in Celsius")
    var until: Float = 65

    @Option(name: .shortAndLong, help: "Priority (higher wins)")
    var priority: Int = 900

    @Flag(name: .long, help: "Use max fan action")
    var max: Bool = true

    @Option(name: .long, help: "Set explicit RPM instead of max (when --max is false)")
    var rpm: Int = 0

    func run() throws {
        let action: ThermalRuleAction = max ? .setMax : .setRPM(rpm)
        let rule = ThermalRule(
            name: name,
            enabled: true,
            priority: priority,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: trigger),
            action: action,
            untilTempBelowC: until
        )

        var rules = RulePersistence.load()
        rules.append(rule)
        try RulePersistence.save(rules)

        print("Added rule: \(rule.id)")
    }
}

struct RulesRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a rule by ID"
    )

    @Argument(help: "Rule ID")
    var id: String

    func run() throws {
        var rules = RulePersistence.load()
        let before = rules.count
        rules.removeAll(where: { $0.id == id })
        try RulePersistence.save(rules)
        let removed = before - rules.count
        print(removed > 0 ? "Removed \(removed) rule(s)." : "No matching rule.")
    }
}

struct RulesEnable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable a rule by ID"
    )

    @Argument(help: "Rule ID")
    var id: String

    func run() throws {
        var rules = RulePersistence.load()
        guard let idx = rules.firstIndex(where: { $0.id == id }) else {
            throw ValidationError("Rule not found: \(id)")
        }
        rules[idx].enabled = true
        try RulePersistence.save(rules)
        print("Enabled rule: \(id)")
    }
}

struct RulesDisable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a rule by ID"
    )

    @Argument(help: "Rule ID")
    var id: String

    func run() throws {
        var rules = RulePersistence.load()
        guard let idx = rules.firstIndex(where: { $0.id == id }) else {
            throw ValidationError("Rule not found: \(id)")
        }
        rules[idx].enabled = false
        try RulePersistence.save(rules)
        print("Disabled rule: \(id)")
    }
}

struct RulesTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Evaluate rules against synthetic temperatures"
    )

    @Option(name: .long, help: "CPU temperature in Celsius")
    var cpu: Float = 60

    @Option(name: .long, help: "GPU temperature in Celsius")
    var gpu: Float = 58

    func run() throws {
        let rules = RulePersistence.load()
        let engine = RuleEngine(rules: rules, isEnabled: true)
        let maxTemp = max(cpu, gpu)
        let context = RuleEvaluationContext(cpuTemp: cpu, gpuTemp: gpu, maxTemp: maxTemp)
        if let decision = engine.evaluate(context: context) {
            print("Matched rule: \(decision.sourceRuleName) [\(decision.sourceRuleID)]")
            if let command = decision.command {
                print("Command: \(command)")
            }
            if let profileID = decision.profileID {
                print("Profile: \(profileID)")
            }
        } else {
            print("No rule matched.")
        }
    }
}

// MARK: - Install

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the background daemon (one-time, requires sudo)"
    )

    func run() throws {
        guard geteuid() == 0 else {
            throw ValidationError("Run with sudo: sudo thermalforge install")
        }

        let binaryPath = ProcessInfo.processInfo.arguments[0]
        let installPath = ThermalForgeDaemon.installPath

        // Copy binary to /usr/local/bin
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: "/usr/local/bin",
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: installPath) {
            try fm.removeItem(atPath: installPath)
        }
        try fm.copyItem(atPath: binaryPath, toPath: installPath)

        // Write launchd plist
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(ThermalForgeDaemon.label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(installPath)</string>
                    <string>daemon</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>ProcessType</key>
                <string>Adaptive</string>
                <key>LowPriorityIO</key>
                <true/>
            </dict>
            </plist>
            """
        try plist.write(
            toFile: ThermalForgeDaemon.plistPath,
            atomically: true, encoding: .utf8
        )
        // Stop a loaded older daemon before bootstrapping the replacement. Do
        // not gate on socket health because socket paths can change by version.
        let launchd = LaunchdCoordinator()
        if case .loaded = try launchd.serviceState(label: ThermalForgeDaemon.label) {
            try launchd.bootout(label: ThermalForgeDaemon.label)
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Start new daemon
        try launchd.bootstrap(plistPath: ThermalForgeDaemon.plistPath)

        // Verify
        Thread.sleep(forTimeInterval: 1.0)
        guard ThermalForgeDaemon.isRunning else {
            throw ValidationError("Daemon failed to start. Try: sudo launchctl list | grep thermalforge")
        }
        print("Done.")
    }
}

// MARK: - Uninstall

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the background daemon"
    )

    func run() throws {
        guard geteuid() == 0 else {
            throw ValidationError("Run with sudo: sudo thermalforge uninstall")
        }

        let cleanup = UninstallCleanup()
        print("Removal targets:")
        for target in cleanup.targets {
            print("  \(target.path)")
        }

        // Stop the app if running so it cannot reassert fan control.
        _ = try ApplicationLifecycleCoordinator().stop(applicationName: "ThermalForgeApp")

        // Reset fans
        do {
            try FanControl().resetAuto()
        } catch {
            print("Warning: unable to reset fans to Apple defaults: \(error.localizedDescription)")
        }

        let launchd = LaunchdCoordinator()
        switch try launchd.serviceState(label: ThermalForgeDaemon.label) {
        case .notLoaded:
            print("Daemon already stopped.")
        case .loaded:
            try launchd.bootout(label: ThermalForgeDaemon.label)
            print("Daemon stopped.")
        }

        let results = cleanup.remove()
        print("Removal results:")
        var failures: [UninstallRemovalResult] = []
        for result in results {
            switch result.outcome {
            case .removed:
                print("  Removed: \(result.path.path)")
            case .alreadyAbsent:
                print("  Already absent: \(result.path.path)")
            case let .failed(message):
                print("  Failed: \(result.path.path) — \(message)")
                failures.append(result)
            }
        }

        guard failures.isEmpty else {
            throw ValidationError("Uninstall incomplete: \(failures.count) path(s) could not be removed")
        }

        print("ThermalForge fully uninstalled.")
        print("Removed: daemon, binary, app, calibration data, logs.")
    }
}

// MARK: - Daemon

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the privileged socket server (called by launchd)"
    )

    func run() throws {
        let fc = try FanControl()
        let server = try DaemonServer(fanControl: fc)
        server.run()
    }
}
