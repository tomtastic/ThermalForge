import ArgumentParser
import Foundation
import ThermalForgeCore

struct Calibrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "calibrate", abstract: "Run an exclusive backend thermal calibration job")
    @Option(name: .shortAndLong, help: "Calibration mode: quick, standard, optimized") var mode = "standard"
    @Option(name: .shortAndLong, help: "Stress type: combined, cpu, gpu") var stress = "combined"
    @Option(name: .long, help: "Reuse a known-safe workload intensity (0.001–0.5)") var intensity: Float?
    @Flag(name: .long, help: "Rediscover workload intensity") var rediscoverIntensity = false
    @Flag(name: .long, help: "Allow replacing a higher-quality calibration") var force = false
    @Flag(name: .long, help: "Clear saved calibration for every lid state") var reset = false
    @Flag(name: .long, help: "Take control from the menu-bar app") var takeover = false

    func run() async throws {
        let client = BackendClient()
        if reset {
            try await client.resetCalibration()
            print("Machine calibration reset.")
            return
        }
        let initial = try await client.startCalibration(CalibrationJobParameters(mode: mode,
            stressType: stress, force: force, rediscoverIntensity: rediscoverIntensity,
            workloadIntensity: intensity), takeover: takeover)
        guard let jobID = initial.calibration?.id else { throw ValidationError("Backend did not return a calibration job.") }
        print("Calibration accepted. Ctrl-C cancels workloads and requests verified Apple handback.")
        let cancellation = CancellationToken()
        let interrupts = InterruptSignalSource { _ = cancellation.cancel() }
        defer { interrupts.cancel() }
        var cancelling = false
        var lastMessage = ""
        do {
            while true {
                if cancellation.isCancelled && !cancelling {
                    _ = try await client.cancelCalibration()
                    cancelling = true
                }
                let state = try await client.maintain()
                guard let job = state.calibration, job.id == jobID else {
                    throw ValidationError("Calibration job was interrupted; no completion was acknowledged.")
                }
                if job.message != lastMessage { print(job.message); lastMessage = job.message }
                switch job.phase {
                case .completed, .cancelled, .failed:
                    _ = try await waitForRestoration(client)
                    _ = try await client.release()
                    if job.phase == .failed { throw ValidationError("Calibration failed: \(job.message)") }
                    if job.phase == .cancelled { print("Calibration cancelled; Apple control verified."); throw ExitCode(130) }
                    print("Calibration complete; Apple control verified.")
                    return
                case .pending, .running, .cancelling, .saving: break
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            // A stale/revoked session release cannot affect a replacement owner.
            _ = try? await client.release()
            throw error
        }
    }
}
