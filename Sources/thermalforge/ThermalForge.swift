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
