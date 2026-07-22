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
