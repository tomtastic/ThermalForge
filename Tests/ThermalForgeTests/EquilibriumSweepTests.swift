import Foundation
import Testing

@testable import ThermalForgeCore

private final class SweepWorkload: CalibrationWorkload {
    private(set) var startIntensities: [Float] = []
    private(set) var stopCount = 0
    private var running = false

    func start(intensity: Float) -> Bool {
        guard !running else { return false }
        running = true
        startIntensities.append(intensity)
        return true
    }

    func stop() -> Bool {
        guard running else { return false }
        running = false
        stopCount += 1
        return true
    }
}

private final class SweepClock {
    private(set) var time: TimeInterval = 0

    func wait(for interval: TimeInterval) {
        time += interval
    }
}

@Suite("Equilibrium sweep")
struct EquilibriumSweepTests {
    @Test("A timed-out level is excluded instead of becoming a measurement")
    func timeoutExcludesLevel() throws {
        let workload = SweepWorkload()
        let clock = SweepClock()
        var fanTargets: [Float] = []
        let sweep = makeSweep(
            configuration: .init(maximumWaitPerLevel: 3, sampleInterval: 1),
            levels: [1],
            workload: workload,
            clock: clock,
            temperature: 60,
            setFanRPM: { fanTargets.append($0) }
        )

        let result = try sweep.run()

        #expect(result.measurements.isEmpty)
        #expect(result.unstableFanLevels == [100])
        #expect(fanTargets == [8_000])
        #expect(workload.startIntensities == [0.025])
        #expect(workload.stopCount == 1)
    }

    @Test("Reaching the ceiling records the boundary and skips lower fan levels")
    func ceilingStopsLowerLevels() throws {
        let workload = SweepWorkload()
        let clock = SweepClock()
        var fanTargets: [Float] = []
        var sampleCount = 0
        let sweep = makeSweep(
            configuration: .init(maximumWaitPerLevel: 10, sampleInterval: 1),
            levels: [1, 0.8],
            workload: workload,
            clock: clock,
            temperature: 85,
            setFanRPM: { fanTargets.append($0) },
            onSample: { _, _ in sampleCount += 1 }
        )

        let result = try sweep.run()

        #expect(result.measurements == [
            .init(fanPercent: 1, equilibriumTemperature: 84),
        ])
        #expect(result.unstableFanLevels.isEmpty)
        #expect(fanTargets == [8_000])
        #expect(sampleCount == 1)
        #expect(workload.stopCount == 1)
    }

    private func makeSweep(
        configuration: EquilibriumSweep.Configuration,
        levels: [Float],
        workload: SweepWorkload,
        clock: SweepClock,
        temperature: Float,
        setFanRPM: @escaping (Float) throws -> Void,
        onSample: @escaping (Float, CalibrationTemperatureSample) -> Void = { _, _ in }
    ) -> EquilibriumSweep {
        EquilibriumSweep(
            configuration: configuration,
            levels: levels,
            minimumRPM: 2_000,
            maximumRPM: 8_000,
            workloadIntensity: 0.025,
            workload: workload,
            convergence: CalibrationConvergenceModel(mode: .optimized),
            setFanRPM: setFanRPM,
            setMaximumFans: {},
            sample: {
                .init(selected: temperature, cpu: temperature, gpu: temperature - 10)
            },
            onSample: onSample,
            now: { clock.time },
            wait: { clock.wait(for: $0) },
            checkCancellation: {},
            log: { _ in }
        )
    }
}
