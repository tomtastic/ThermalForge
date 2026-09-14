import ArgumentParser
import Foundation
import ThermalForgeCore

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch", abstract: "Run a backend profile and display measured sensors until interrupted")
    @Option(name: .shortAndLong, help: "Profile ID") var profile = "balanced"
    @Option(name: .shortAndLong, help: "Display interval in seconds") var interval = 1.0
    @Flag(name: .long, help: "Output sensor JSON on each update") var json = false
    @Flag(name: .long, help: "Take control from the menu-bar app") var takeover = false

    func run() async throws {
        guard interval.isFinite, interval >= 0.2 else { throw ValidationError("Interval must be at least 0.2 seconds.") }
        let client = BackendClient()
        _ = try await client.acquire(.profile(profile), takeover: takeover)
        if !json { print("ThermalForge watch — \(profile). Ctrl-C to release to Apple control.") }
        try await runForegroundSession(client: client, interval: interval) { state in
            guard let status = state.sensors else {
                if !json { print("Sensors unavailable; ownership: \(state.restoration.rawValue)") }
                return
            }
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.keyEncodingStrategy = .convertToSnakeCase
                if let data = try? encoder.encode(status) { print(String(decoding: data, as: UTF8.self)) }
            } else {
                let temperatures = TemperatureSummary(status.temperatures)
                let cpu = temperatures.cpu.map { String(format: "%.0f", $0) } ?? "?"
                let gpu = temperatures.gpu.map { String(format: "%.0f", $0) } ?? "?"
                let fan = status.fans.first.map { String($0.actualRPM) } ?? "?"
                print("[\(ISO8601DateFormatter().string(from: Date()))] CPU: \(cpu)°C  GPU: \(gpu)°C  Fan: \(fan) RPM  [\(state.acknowledgedControl)]")
            }
        }
    }
}
