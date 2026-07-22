import ArgumentParser
import ThermalForgeCore

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the privileged socket server (called by launchd)"
    )

    func run() throws {
        let fanControl = try FanControl()
        let server = try DaemonServer(fanControl: fanControl)
        server.run()
    }
}
