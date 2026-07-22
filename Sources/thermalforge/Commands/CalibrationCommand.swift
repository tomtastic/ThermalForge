import ArgumentParser
import Darwin
import Foundation
import ThermalForgeCore

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
                    "Run with sudo to clear both root and console-user data: "
                        + "sudo thermalforge calibrate --reset"
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

        if CalibrationRunner.wouldDowngrade(mode: calMode) {
            let existing = CalibrationData.load()
            let existingMode = existing?.mode ?? "unknown"
            throw ValidationError(
                "Existing calibration was run at '\(existingMode)' level. "
                    + "Running '\(mode)' would downgrade your data. "
                    + "Use --mode \(existingMode) or higher."
            )
        }

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
                for measurement in data.measurements {
                    print("  \(Int(measurement.targetTemp))°C → \(Int(measurement.holdingRPMPercent * 100))% fan speed")
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
