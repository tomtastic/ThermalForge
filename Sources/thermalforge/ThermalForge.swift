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
