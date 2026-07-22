import Foundation

public enum LegacyRuleMigrationResult: Equatable {
    case alreadyCompleted
    case noLegacySettings
    case existingRulePreserved
    case migrated
}

public enum LegacyTemperatureRuleMigration {
    public static let ruleID = "thermalforge.quick-temperature-rule"

    private static let migrationVersion = 1
    private static let migrationKey = "legacyTemperatureRuleMigrationVersion"
    private static let enabledKey = "customRuleEnabled"
    private static let triggerKey = "customRuleTriggerTempC"
    private static let releaseKey = "customRuleReleaseTempC"
    private static let fanPercentKey = "customRuleFanPercent"

    @discardableResult
    public static func migrate(
        userDefaults: UserDefaults = .standard,
        rulesFilePath: URL = RulePersistence.filePath
    ) throws -> LegacyRuleMigrationResult {
        guard userDefaults.integer(forKey: migrationKey) < migrationVersion else {
            return .alreadyCompleted
        }

        let legacyKeys = [enabledKey, triggerKey, releaseKey, fanPercentKey]
        guard legacyKeys.contains(where: { userDefaults.object(forKey: $0) != nil }) else {
            userDefaults.set(migrationVersion, forKey: migrationKey)
            return .noLegacySettings
        }

        let rules = RulePersistence.load(from: rulesFilePath)
        guard !rules.contains(where: { $0.id == ruleID }) else {
            userDefaults.set(migrationVersion, forKey: migrationKey)
            return .existingRulePreserved
        }

        let enabled = (userDefaults.object(forKey: enabledKey) as? NSNumber)?.boolValue ?? false
        let trigger = clamped(
            number(userDefaults, forKey: triggerKey, default: 55),
            minimum: 40,
            maximum: 95
        )
        let release = clamped(
            number(userDefaults, forKey: releaseKey, default: 50),
            minimum: 35,
            maximum: trigger - 1
        )
        let fanPercent = clamped(
            number(userDefaults, forKey: fanPercentKey, default: 100),
            minimum: 20,
            maximum: 100
        )

        let rule = ThermalRule(
            id: ruleID,
            name: "IF temp ≥ \(Int(trigger))°C THEN \(Int(fanPercent))% until ≤ \(Int(release))°C",
            enabled: enabled,
            priority: 1_000,
            condition: ThermalRuleCondition(
                metric: .maxTemp,
                comparator: .greaterThanOrEqual,
                valueCelsius: Float(trigger)
            ),
            action: .setFanPercent(Float(fanPercent / 100)),
            untilTempBelowC: Float(release)
        )
        try RulePersistence.add(rule, to: rulesFilePath)
        userDefaults.set(migrationVersion, forKey: migrationKey)
        return .migrated
    }

    private static func number(
        _ userDefaults: UserDefaults,
        forKey key: String,
        default defaultValue: Double
    ) -> Double {
        (userDefaults.object(forKey: key) as? NSNumber)?.doubleValue ?? defaultValue
    }

    private static func clamped(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }
}
