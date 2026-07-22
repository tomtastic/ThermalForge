import Foundation
import Testing

@testable import ThermalForgeCore

private final class SimulatedIntensityWorkload: CalibrationWorkload {
    private(set) var activeIntensity: Float?
    private(set) var testedIntensities: [Float] = []
    private(set) var stopCount = 0

    func start(intensity: Float) -> Bool {
        guard activeIntensity == nil else { return false }
        activeIntensity = intensity
        testedIntensities.append(intensity)
        return true
    }

    func stop() -> Bool {
        guard activeIntensity != nil else { return false }
        activeIntensity = nil
        stopCount += 1
        return true
    }
}

private final class ManualCalibrationClock {
    private(set) var time: TimeInterval = 0

    func wait(for interval: TimeInterval) {
        time += interval
    }
}

@Suite("Workload intensity finder")
struct WorkloadIntensityFinderTests {
    @Test("A rejected hotter probe selects the prior safe candidate and requests cooldown")
    func hotRejectionPreservesSafeCandidate() throws {
        let workload = SimulatedIntensityWorkload()
        let clock = ManualCalibrationClock()
        var configuration = testConfiguration()
        configuration.maximumIterations = 2
        let finder = makeFinder(
            configuration: configuration,
            workload: workload,
            clock: clock,
            activeTemperature: { intensity in intensity <= 0.05 ? 55 : 75 }
        )

        let result = try finder.find()
        let selection = try #require(result)

        #expect(abs(selection.intensity - 0.05) < 0.000_001)
        #expect(selection.requiresCooldown)
        #expect(workload.testedIntensities == [0.05, 0.1])
        #expect(workload.stopCount == 2)
    }

    @Test("The initial useful safe probe is selected without extra trials")
    func usefulSafeProbeStopsDiscovery() throws {
        let workload = SimulatedIntensityWorkload()
        let clock = ManualCalibrationClock()
        var maximumFanRequests = 0
        let finder = makeFinder(
            configuration: testConfiguration(),
            workload: workload,
            clock: clock,
            activeTemperature: { _ in 60 },
            setMaximumFans: { maximumFanRequests += 1 }
        )

        let result = try finder.find()
        let selection = try #require(result)

        #expect(abs(selection.intensity - 0.05) < 0.000_001)
        #expect(!selection.requiresCooldown)
        #expect(workload.testedIntensities == [0.05])
        #expect(maximumFanRequests == 1)
    }

    @Test("Cooldown timeout is reported and discovery proceeds")
    func cooldownTimeoutProceeds() throws {
        let workload = SimulatedIntensityWorkload()
        let clock = ManualCalibrationClock()
        var configuration = testConfiguration()
        configuration.cooldownMaximumWait = 3
        configuration.cooldownPollInterval = 1
        var inactiveSamples = 0
        var messages: [String] = []

        let finder = WorkloadIntensityFinder(
            configuration: configuration,
            stressDescription: "test",
            temperature: {
                if workload.activeIntensity != nil { return 60 }
                inactiveSamples += 1
                return inactiveSamples == 1 ? 45 : 55
            },
            workload: workload,
            setMaximumFans: {},
            now: { clock.time },
            wait: { clock.wait(for: $0) },
            checkCancellation: {},
            log: { messages.append($0) }
        )

        let result = try finder.find()
        let selection = try #require(result)

        #expect(abs(selection.intensity - 0.05) < 0.000_001)
        #expect(messages.contains { $0.contains("Cooldown timeout: 55.0°C vs target 45.0°C") })
        #expect(workload.stopCount == 1)
    }

    @Test("Failure at minimum intensity returns no selection")
    func minimumIntensityFailure() throws {
        let workload = SimulatedIntensityWorkload()
        let clock = ManualCalibrationClock()
        let finder = makeFinder(
            configuration: testConfiguration(),
            workload: workload,
            clock: clock,
            activeTemperature: { _ in 75 }
        )

        #expect(try finder.find() == nil)
        #expect(abs((workload.testedIntensities.last ?? 0) - 0.001) < 0.000_001)
        #expect(workload.stopCount == workload.testedIntensities.count)
    }

    private func testConfiguration() -> WorkloadIntensityFinder.Configuration {
        var configuration = WorkloadIntensityFinder.Configuration()
        configuration.minimumDecisionDuration = 2
        configuration.checkDuration = 2
        configuration.thermalTimeConstant = 0.01
        configuration.observationInterval = 1
        configuration.cooldownStabilityInterval = 0.1
        return configuration
    }

    private func makeFinder(
        configuration: WorkloadIntensityFinder.Configuration,
        workload: SimulatedIntensityWorkload,
        clock: ManualCalibrationClock,
        activeTemperature: @escaping (Float) -> Float,
        setMaximumFans: @escaping () throws -> Void = {}
    ) -> WorkloadIntensityFinder {
        WorkloadIntensityFinder(
            configuration: configuration,
            stressDescription: "test",
            temperature: {
                workload.activeIntensity.map(activeTemperature) ?? 45
            },
            workload: workload,
            setMaximumFans: setMaximumFans,
            now: { clock.time },
            wait: { clock.wait(for: $0) },
            checkCancellation: {},
            log: { _ in }
        )
    }
}
