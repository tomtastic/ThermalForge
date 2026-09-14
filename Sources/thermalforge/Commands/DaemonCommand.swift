import ArgumentParser
import Darwin
import Foundation
import ThermalForgeCore

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the privileged socket server (called by launchd)"
    )

    func run() throws {
        guard geteuid() == 0 else { throw ValidationError("The backend must run as root via launchd") }
        let generation = UUID().uuidString
        let recovery = try RecoveryClient(generation: generation)
        let fanControl = try FanControl()
        let coordinator = BackendCoordinator(sensorProvider: fanControl, actuator: fanControl,
            recovery: recovery, generation: generation, onFatalFailure: { message in
                NSLog("ThermalForge backend exiting: %@", message)
                Darwin.exit(1)
            })
        let server = try DaemonServer(coordinator: coordinator)
        let lifetime = BackendServiceRuntime(coordinator: coordinator, recovery: recovery)
        lifetime.start()
        server.run()
        withExtendedLifetime(lifetime) {}
    }
}

struct Recovery: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "recovery",
        abstract: "Run independent fan recovery (called by launchd)")
    func run() throws {
        guard geteuid() == 0 else { throw ValidationError("Recovery must run as root via launchd") }
        try RecoveryService(fanControl: FanControl()).run()
    }
}
