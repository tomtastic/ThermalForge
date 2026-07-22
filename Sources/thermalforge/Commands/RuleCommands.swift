import ArgumentParser
import Foundation
import ThermalForgeCore

struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Manage IF/THEN/ELSE thermal rules",
        subcommands: [
            RulesList.self,
            RulesAdd.self,
            RulesRemove.self,
            RulesEnable.self,
            RulesDisable.self,
            RulesTest.self,
        ]
    )
}

struct RulesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all persisted rules"
    )

    func run() throws {
        let rules = RulePersistence.load().sorted { lhs, rhs in
            if lhs.priority == rhs.priority { return lhs.name < rhs.name }
            return lhs.priority > rhs.priority
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        print(String(data: data, encoding: .utf8) ?? "[]")
    }
}

struct RulesAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a rule (example: IF temp >= 55 THEN max until <= 65)"
    )

    @Option(name: .shortAndLong, help: "Rule name")
    var name: String = "IF temp >= 55 THEN max until <= 65"

    @Option(name: .shortAndLong, help: "Trigger threshold in Celsius")
    var trigger: Float = 55

    @Option(name: .long, help: "Latch release threshold in Celsius")
    var until: Float = 65

    @Option(name: .shortAndLong, help: "Priority (higher wins)")
    var priority: Int = 900

    @Flag(name: .long, help: "Use max fan action")
    var max: Bool = true

    @Option(name: .long, help: "Set explicit RPM instead of max (when --max is false)")
    var rpm: Int = 0

    func run() throws {
        let action: ThermalRuleAction = max ? .setMax : .setRPM(rpm)
        let rule = ThermalRule(
            name: name,
            enabled: true,
            priority: priority,
            condition: ThermalRuleCondition(
                metric: .maxTemp,
                comparator: .greaterThanOrEqual,
                valueCelsius: trigger
            ),
            action: action,
            untilTempBelowC: until
        )

        try RulePersistence.add(rule)

        print("Added rule: \(rule.id)")
    }
}

struct RulesRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a rule by ID"
    )

    @Argument(help: "Rule ID")
    var id: String

    func run() throws {
        let result = try RulePersistence.remove(id: id)
        print(result.removedCount > 0 ? "Removed \(result.removedCount) rule(s)." : "No matching rule.")
    }
}

struct RulesEnable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable a rule by ID"
    )

    @Argument(help: "Rule ID")
    var id: String

    func run() throws {
        guard try RulePersistence.enable(id: id) != nil else {
            throw ValidationError("Rule not found: \(id)")
        }
        print("Enabled rule: \(id)")
    }
}

struct RulesDisable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a rule by ID"
    )

    @Argument(help: "Rule ID")
    var id: String

    func run() throws {
        guard try RulePersistence.disable(id: id) != nil else {
            throw ValidationError("Rule not found: \(id)")
        }
        print("Disabled rule: \(id)")
    }
}

struct RulesTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Evaluate rules against synthetic temperatures"
    )

    @Option(name: .long, help: "CPU temperature in Celsius")
    var cpu: Float = 60

    @Option(name: .long, help: "GPU temperature in Celsius")
    var gpu: Float = 58

    func run() throws {
        let rules = RulePersistence.load()
        let engine = RuleEngine(rules: rules, isEnabled: true)
        let maxTemp = max(cpu, gpu)
        let context = RuleEvaluationContext(cpuTemp: cpu, gpuTemp: gpu, maxTemp: maxTemp)
        if let decision = engine.evaluate(context: context) {
            print("Matched rule: \(decision.sourceRuleName) [\(decision.sourceRuleID)]")
            if let command = decision.command {
                print("Command: \(command)")
            }
            if let profileID = decision.profileID {
                print("Profile: \(profileID)")
            }
        } else {
            print("No rule matched.")
        }
    }
}
