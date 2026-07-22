import ArgumentParser
import Foundation
import ThermalForgeCore

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
