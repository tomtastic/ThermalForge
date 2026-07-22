import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Thermal monitor sequences")
struct ThermalMonitorSequenceTests {
    @Test("Safety override preempts control until its hysteresis clears")
    func safetySequence() {
        let harness = MonitorHarness(profile: .silent)

        harness.tick(at: 96)
        #expect(harness.monitor.state == .safetyOverride)
        #expect(harness.commands.values == [.setMax])

        harness.tick(at: 92)
        #expect(harness.monitor.state == .safetyOverride)
        #expect(harness.commands.values == [.setMax])

        for _ in 0..<4 {
            harness.tick(at: 92)
        }
        #expect(harness.commands.values == [.setMax, .setMax])

        harness.tick(at: 89)
        #expect(harness.monitor.state == .idle)
        #expect(harness.commands.values == [.setMax, .setMax, .resetAuto])
    }

    @Test("A matching rule preempts a hands-off profile")
    func rulePreemption() {
        let rule = ThermalRule(
            id: "hot",
            name: "Hot",
            condition: ThermalRuleCondition(
                metric: .maxTemp,
                comparator: .greaterThanOrEqual,
                valueCelsius: 60
            ),
            action: .setMax
        )
        let harness = MonitorHarness(profile: .silent, rules: [rule])

        harness.tick(at: 70)

        #expect(harness.commands.values == [.setMax])
        #expect(harness.monitor.state == .active(profileName: "Rule: Hot"))
        #expect(harness.monitor.activeProfile == .silent)
    }

    @Test("Smart fan speed ramps by its per-tick governor")
    func smartRamping() {
        let harness = MonitorHarness(profile: .smart)

        for _ in 0..<5 {
            harness.tick(at: 70)
        }
        #expect(harness.commands.values.isEmpty)

        harness.tick(at: 70)
        harness.tick(at: 70)

        #expect(harness.commands.values == [.setRPM(2317), .setRPM(2317)])
        #expect(harness.monitor.state == .active(profileName: "Smart"))
    }

    @Test("A curve profile remains engaged through its hysteresis band")
    func profileHysteresis() {
        let harness = MonitorHarness(profile: .balanced)

        for _ in 0..<8 {
            harness.tick(at: 70)
        }
        #expect(harness.commands.values.last == .setRPM(2317))

        let commandCount = harness.commands.values.count
        harness.tick(at: 52)
        #expect(!harness.commands.values[commandCount...].contains(.resetAuto))

        harness.tick(at: 49)
        #expect(harness.commands.values.last == .resetAuto)
        #expect(harness.monitor.state == .idle)
    }

    @Test("Idle cadence relaxes and returns to active near the safety range")
    func adaptiveCadence() {
        let harness = MonitorHarness(profile: .silent)

        for _ in 0..<8 {
            harness.tick(at: 45)
        }
        #expect(harness.monitor.currentTickInterval == 5)

        harness.tick(at: 90)
        #expect(harness.monitor.currentTickInterval == 1)
    }
}

private final class MonitorHarness {
    let sensor = MutableSensorProvider()
    let clock = TestClock()
    let commands = CommandRecorder()
    let monitor: ThermalMonitor

    init(profile: FanProfile, rules: [ThermalRule] = []) {
        let controlService = ControlService(ruleEngine: RuleEngine(rules: rules))
        monitor = ThermalMonitor(
            sensorProvider: sensor,
            profile: profile,
            controlService: controlService,
            lidStateProvider: FixedMonitorLidStateProvider(),
            now: { [clock] in clock.value },
            calibrationLoader: { _ in nil },
            anomalyObserver: NoOpAnomalyObserver()
        )
        monitor.onFanCommand = { [commands] command in
            commands.values.append(command)
        }
    }

    func tick(at temperature: Float) {
        sensor.temperature = temperature
        clock.value += 1
        monitor.tick()
    }
}

private final class MutableSensorProvider: SensorProvider {
    var temperature: Float = 45

    func status() throws -> ThermalStatus {
        ThermalStatus(
            fans: [
                ThermalStatus.FanStatus(
                    index: 0,
                    actualRPM: 2317,
                    targetRPM: 2317,
                    minRPM: 2317,
                    maxRPM: 7826,
                    mode: "forced"
                ),
            ],
            temperatures: ["Tp01": temperature, "Tg01": temperature - 2]
        )
    }
}

private final class TestClock {
    var value: TimeInterval = 0
}

private final class CommandRecorder {
    var values: [FanCommand] = []
}

private struct FixedMonitorLidStateProvider: LidStateProvider {
    let isLidClosed = false
}

private final class NoOpAnomalyObserver: ThermalAnomalyObserving {
    func observe(
        status: ThermalStatus,
        maxTemp: Float,
        profileName: String,
        isCalibrating: Bool
    ) {}
}
