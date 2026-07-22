import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Calibration cooldown")
struct CalibrationCooldownTests {
    @Test("A stable below-threshold baseline returns on the third sample")
    func reachableBaselineReturnsPromptly() throws {
        var samples = [Float](repeating: 44, count: 3)
        var waits: [TimeInterval] = []
        var maximumFanRequests = 0
        var messages: [String] = []
        let cooldown = CalibrationCooldown(
            convergence: CalibrationConvergenceModel(mode: .optimized),
            setMaximumFans: { maximumFanRequests += 1 },
            temperature: { samples.removeFirst() },
            wait: { waits.append($0) },
            checkCancellation: {},
            log: { messages.append($0) }
        )

        try cooldown.run(below: 45)

        #expect(samples.isEmpty)
        #expect(waits == [2, 2])
        #expect(maximumFanRequests == 1)
        #expect(messages == ["Cooled to 44.0°C"])
    }

    @Test("A warm but stable baseline avoids waiting for an unreachable target")
    func stableWarmBaselineReturns() throws {
        var sampleCount = 0
        var waitCount = 0
        var messages: [String] = []
        let cooldown = CalibrationCooldown(
            convergence: CalibrationConvergenceModel(mode: .optimized),
            setMaximumFans: {},
            temperature: {
                sampleCount += 1
                return 50
            },
            wait: { _ in waitCount += 1 },
            checkCancellation: {},
            log: { messages.append($0) }
        )

        try cooldown.run(below: 45)

        #expect(sampleCount == 15)
        #expect(waitCount == 14)
        #expect(messages == ["Baseline stabilized at 50.0°C"])
    }
}
