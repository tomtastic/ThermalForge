import Testing

@testable import ThermalForgeCore

@Suite("Monitor timing")
struct MonitorTimingTests {
    @Test("Elapsed cadence is due initially and at its deadline")
    func elapsedCadenceDeadline() {
        #expect(ElapsedCadence.isDue(lastRun: nil, now: 10, interval: 0.5))
        #expect(!ElapsedCadence.isDue(lastRun: 10, now: 10.49, interval: 0.5))
        #expect(ElapsedCadence.isDue(lastRun: 10, now: 10.5, interval: 0.5))
    }

    @Test("Temperature rate uses actual irregular sample times")
    func rateUsesElapsedTime() {
        var history = TemperatureRateHistory()
        history.record(50, at: 0)
        history.record(54, at: 2)
        history.record(62, at: 6)

        #expect(history.ratePerSecond == 2)
    }

    @Test("Temperature history retains only its configured capacity")
    func historyCapacity() {
        var history = TemperatureRateHistory(capacity: 2)
        history.record(40, at: 0)
        history.record(50, at: 2)
        history.record(70, at: 4)

        #expect(history.ratePerSecond == 10)
        history.removeAll()
        #expect(history.ratePerSecond == 0)
    }
}
