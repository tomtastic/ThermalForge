import ArgumentParser
import Foundation
import ThermalForgeCore

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

    private func parseDuration(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("h"), let number = Double(trimmed.dropLast()) {
            return number * 3600
        }
        if trimmed.hasSuffix("m"), let number = Double(trimmed.dropLast()) {
            return number * 60
        }
        if trimmed.hasSuffix("s"), let number = Double(trimmed.dropLast()) {
            return number
        }
        return Double(trimmed)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration >= 3600 { return "\(Int(duration / 3600))h" }
        if duration >= 60 { return "\(Int(duration / 60))m" }
        return "\(Int(duration))s"
    }
}
