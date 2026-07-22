import Testing

@testable import ThermalForgeCore

@Suite("Rule Engine")
struct RuleEngineTests {
    @Test("Fan-percentage actions remain machine-independent")
    func fanPercentageDecision() {
        let rule = ThermalRule(
            id: "percent",
            name: "Percent",
            condition: ThermalRuleCondition(
                metric: .maxTemp,
                comparator: .greaterThanOrEqual,
                valueCelsius: 60
            ),
            action: .setFanPercent(0.65)
        )
        let engine = RuleEngine(rules: [rule])

        let decision = engine.evaluate(context: .init(cpuTemp: 65, gpuTemp: 50, maxTemp: 65))

        #expect(decision?.command == nil)
        #expect(decision?.fanPercent == 0.65)
        #expect(decision?.sourceRuleID == "percent")
    }

    @Test("Highest priority matching rule wins")
    func highestPriorityWins() {
        let low = ThermalRule(
            id: "low",
            name: "low",
            enabled: true,
            priority: 10,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setRPM(3000)
        )
        let high = ThermalRule(
            id: "high",
            name: "high",
            enabled: true,
            priority: 100,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setMax
        )

        let engine = RuleEngine(rules: [low, high], isEnabled: true)
        let decision = engine.evaluate(context: RuleEvaluationContext(cpuTemp: 56, gpuTemp: 52, maxTemp: 56))

        #expect(decision != nil)
        #expect(decision?.sourceRuleID == "high")
        #expect(decision?.command == .setMax)
    }

    @Test("Latched rule stays active until release threshold")
    func latchedRule() {
        let rule = ThermalRule(
            id: "latched",
            name: "latched",
            enabled: true,
            priority: 500,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 70),
            action: .setMax,
            untilTempBelowC: 65
        )

        let engine = RuleEngine(rules: [rule], isEnabled: true)

        let hot = engine.evaluate(context: RuleEvaluationContext(cpuTemp: 72, gpuTemp: 70, maxTemp: 72))
        #expect(hot?.command == .setMax)

        let coolingButStillLatched = engine.evaluate(context: RuleEvaluationContext(cpuTemp: 67, gpuTemp: 64, maxTemp: 67))
        #expect(coolingButStillLatched?.command == .setMax)

        let released = engine.evaluate(context: RuleEvaluationContext(cpuTemp: 64, gpuTemp: 63, maxTemp: 64))
        #expect(released == nil)
    }

    @Test("Disabled engine returns no decisions")
    func disabledEngine() {
        let rule = ThermalRule(
            id: "disabled",
            name: "disabled",
            enabled: true,
            priority: 100,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setMax
        )

        let engine = RuleEngine(rules: [rule], isEnabled: false)
        let decision = engine.evaluate(context: RuleEvaluationContext(cpuTemp: 80, gpuTemp: 75, maxTemp: 80))
        #expect(decision == nil)
    }

    @Test("Rules sort by priority then name")
    func sortedOrder() {
        let c = ThermalRule(
            id: "c",
            name: "zeta",
            enabled: true,
            priority: 10,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setMax
        )
        let a = ThermalRule(
            id: "a",
            name: "alpha",
            enabled: true,
            priority: 100,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setMax
        )
        let b = ThermalRule(
            id: "b",
            name: "beta",
            enabled: true,
            priority: 100,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setMax
        )

        let engine = RuleEngine(rules: [c, b, a], isEnabled: true)
        #expect(engine.allRules().map(\.id) == ["a", "b", "c"])
    }

    @Test("Latched rule is cleared when disabled by rule update")
    func latchedRuleClearsWhenDisabled() {
        var rule = ThermalRule(
            id: "latched",
            name: "latched",
            enabled: true,
            priority: 500,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 70),
            action: .setMax,
            untilTempBelowC: 65
        )

        let engine = RuleEngine(rules: [rule], isEnabled: true)
        let hot = RuleEvaluationContext(cpuTemp: 72, gpuTemp: 71, maxTemp: 72)
        #expect(engine.evaluate(context: hot)?.command == .setMax)

        rule.enabled = false
        engine.setRules([rule])
        #expect(engine.evaluate(context: hot) == nil)
    }
}
