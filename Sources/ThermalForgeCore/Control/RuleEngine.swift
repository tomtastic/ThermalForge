import Foundation

public final class RuleEngine {
    private struct CompiledRule {
        let rule: ThermalRule
        let decision: RuleDecision

        var id: String { rule.id }
        var enabled: Bool { rule.enabled }
        var untilTempBelowC: Float? { rule.untilTempBelowC }
        var metric: ThermalMetric { rule.condition.metric }
        var comparator: RuleComparator { rule.condition.comparator }
        var threshold: Float { rule.condition.valueCelsius }
    }

    public var isEnabled: Bool
    private var rules: [ThermalRule]
    private var sortedRules: [ThermalRule]
    private var enabledRules: [CompiledRule]
    private var enabledRulesByID: [String: CompiledRule]
    private var latchedRuleID: String?

    public init(rules: [ThermalRule] = [], isEnabled: Bool = true) {
        self.rules = rules
        self.sortedRules = []
        self.enabledRules = []
        self.enabledRulesByID = [:]
        self.isEnabled = isEnabled
        rebuildCaches()
    }

    public func setRules(_ rules: [ThermalRule]) {
        self.rules = rules
        rebuildCaches()
        if let latchedRuleID, enabledRulesByID[latchedRuleID] == nil {
            self.latchedRuleID = nil
        }
    }

    public func allRules() -> [ThermalRule] {
        sortedRules
    }

    public func evaluate(context: RuleEvaluationContext) -> RuleDecision? {
        guard isEnabled else {
            latchedRuleID = nil
            return nil
        }

        if let latched = resolveLatchedRule(context: context) {
            return latched
        }

        for rule in enabledRules where matches(rule: rule, context: context) {
            if rule.untilTempBelowC != nil {
                latchedRuleID = rule.id
            }
            return rule.decision
        }
        return nil
    }

    private func resolveLatchedRule(context: RuleEvaluationContext) -> RuleDecision? {
        guard let latchedRuleID, let rule = enabledRulesByID[latchedRuleID] else {
            self.latchedRuleID = nil
            return nil
        }

        if let until = rule.untilTempBelowC {
            if context.maxTemp > until {
                return rule.decision
            }
            self.latchedRuleID = nil
            return nil
        }

        self.latchedRuleID = nil
        return nil
    }

    private func matches(rule: CompiledRule, context: RuleEvaluationContext) -> Bool {
        let current: Float
        switch rule.metric {
        case .maxTemp:
            current = context.maxTemp
        case .cpuTemp:
            current = context.cpuTemp
        case .gpuTemp:
            current = context.gpuTemp
        }
        return rule.comparator.evaluate(lhs: current, rhs: rule.threshold)
    }

    private static func makeDecision(rule: ThermalRule) -> RuleDecision {
        let command: FanCommand?
        let fanPercent: Float?
        let profileID: String?

        switch rule.action {
        case .setMax:
            command = .setMax
            fanPercent = nil
            profileID = nil
        case .setRPM(let rpm):
            command = .setRPM(Float(rpm))
            fanPercent = nil
            profileID = nil
        case .setFanPercent(let percent):
            command = nil
            fanPercent = percent
            profileID = nil
        case .resetAuto:
            command = .resetAuto
            fanPercent = nil
            profileID = nil
        case .selectProfile(let id):
            command = nil
            fanPercent = nil
            profileID = id
        }

        return RuleDecision(
            command: command,
            fanPercent: fanPercent,
            profileID: profileID,
            sourceRuleID: rule.id,
            sourceRuleName: rule.name
        )
    }

    private func rebuildCaches() {
        sortedRules = rules.sorted(by: Self.ruleSort)
        enabledRules = sortedRules
            .filter(\.enabled)
            .map { rule in
                CompiledRule(rule: rule, decision: Self.makeDecision(rule: rule))
            }
        enabledRulesByID = Dictionary(uniqueKeysWithValues: enabledRules.map { ($0.id, $0) })
    }

    private static func ruleSort(_ lhs: ThermalRule, _ rhs: ThermalRule) -> Bool {
        if lhs.priority == rhs.priority {
            return lhs.name < rhs.name
        }
        return lhs.priority > rhs.priority
    }
}
