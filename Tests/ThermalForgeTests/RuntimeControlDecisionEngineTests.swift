import Testing

@testable import ThermalForgeCore

@Suite("Runtime control decisions")
struct RuntimeControlDecisionEngineTests {
    @Test("Safety decisions hold, refresh, and clear before profile control resumes")
    func safetyLifecycle() {
        let engine = makeEngine(profile: .silent)

        let triggered = engine.evaluate(input(temp: 96, now: 0))
        let held = engine.evaluate(input(temp: 92, now: 1))
        let refreshed = engine.evaluate(input(temp: 92, now: 5))
        let cleared = engine.evaluate(input(temp: 89, now: 6))

        #expect(triggered.command == .setMax)
        #expect(triggered.notices == [.safetyTriggered(96)])
        #expect(held.command == nil)
        #expect(refreshed.command == .setMax)
        #expect(cleared.command == .resetAuto)
        #expect(cleared.notices.contains(.safetyCleared(89)))
        #expect(engine.state == .idle)
    }

    @Test("Rule decisions preempt profile control without applying cadence")
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
        let engine = makeEngine(profile: .balanced, rules: [rule])

        let output = engine.evaluate(input(temp: 70, now: 1))

        #expect(output.command == .setMax)
        #expect(!output.shouldApplyCadence)
        #expect(output.notices == [.ruleTriggered(id: "hot", name: "Hot")])
        #expect(engine.state == .active(profileName: "Rule: Hot"))
    }

    @Test("Smart decisions expose governed fan commands without performing I/O")
    func smartRamp() {
        let engine = makeEngine(profile: .smart)
        var outputs: [RuntimeControlOutput] = []

        for second in 1...7 {
            outputs.append(engine.evaluate(input(
                temp: 70,
                now: Double(second),
                recordTemperatureRate: second.isMultiple(of: 2)
            )))
        }

        #expect(outputs.prefix(5).allSatisfy { $0.command == nil })
        #expect(outputs[5].command == .setRPM(2317))
        #expect(outputs[6].command == .setRPM(2317))
        #expect(engine.state == .active(profileName: "Smart"))
    }

    private func makeEngine(
        profile: FanProfile,
        rules: [ThermalRule] = []
    ) -> RuntimeControlDecisionEngine {
        RuntimeControlDecisionEngine(
            profile: profile,
            controlService: ControlService(ruleEngine: RuleEngine(rules: rules))
        )
    }

    private func input(
        temp: Float,
        now: Double,
        recordTemperatureRate: Bool = true
    ) -> RuntimeControlInput {
        RuntimeControlInput(
            status: ThermalStatus(
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
                temperatures: ["Tp01": temp, "Tg01": temp - 2]
            ),
            maxTemp: temp,
            fanLimits: RuntimeFanLimits(minRPM: 2317, maxRPM: 7826),
            now: now,
            tickInterval: 1,
            recordTemperatureRate: recordTemperatureRate,
            calibration: nil
        )
    }
}
