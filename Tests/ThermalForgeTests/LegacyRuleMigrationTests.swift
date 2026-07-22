import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Legacy temperature-rule migration")
struct LegacyRuleMigrationTests {
    @Test("Enabled legacy settings become a stable persistent rule")
    func migratesLegacySettings() throws {
        let fixture = MigrationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "customRuleEnabled")
        fixture.defaults.set(72.0, forKey: "customRuleTriggerTempC")
        fixture.defaults.set(63.0, forKey: "customRuleReleaseTempC")
        fixture.defaults.set(65.0, forKey: "customRuleFanPercent")

        let result = try LegacyTemperatureRuleMigration.migrate(
            userDefaults: fixture.defaults,
            rulesFilePath: fixture.rulesPath
        )
        let rules = RulePersistence.load(from: fixture.rulesPath)

        #expect(result == .migrated)
        #expect(rules.count == 1)
        let rule = try #require(rules.first)
        #expect(rule.id == LegacyTemperatureRuleMigration.ruleID)
        #expect(rule.enabled)
        #expect(rule.priority == 1_000)
        #expect(rule.condition == ThermalRuleCondition(
            metric: .maxTemp,
            comparator: .greaterThanOrEqual,
            valueCelsius: 72
        ))
        #expect(rule.action == .setFanPercent(0.65))
        #expect(rule.untilTempBelowC == 63)
    }

    @Test("Migration preserves existing rules and runs only once")
    func preservesRulesAndRunsOnce() throws {
        let fixture = MigrationFixture()
        defer { fixture.cleanUp() }
        let existing = ThermalRule(
            id: "existing",
            name: "Existing",
            condition: ThermalRuleCondition(
                metric: .cpuTemp,
                comparator: .greaterThan,
                valueCelsius: 80
            ),
            action: .setMax
        )
        try RulePersistence.save([existing], to: fixture.rulesPath)
        fixture.defaults.set(true, forKey: "customRuleEnabled")

        #expect(try LegacyTemperatureRuleMigration.migrate(
            userDefaults: fixture.defaults,
            rulesFilePath: fixture.rulesPath
        ) == .migrated)

        fixture.defaults.set(90.0, forKey: "customRuleTriggerTempC")
        #expect(try LegacyTemperatureRuleMigration.migrate(
            userDefaults: fixture.defaults,
            rulesFilePath: fixture.rulesPath
        ) == .alreadyCompleted)

        let rules = RulePersistence.load(from: fixture.rulesPath)
        #expect(rules.count == 2)
        #expect(rules.first == existing)
        #expect(rules.last?.condition.valueCelsius == 55)
    }

    @Test("Out-of-range legacy values are clamped consistently")
    func clampsLegacyValues() throws {
        let fixture = MigrationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: "customRuleEnabled")
        fixture.defaults.set(20.0, forKey: "customRuleTriggerTempC")
        fixture.defaults.set(80.0, forKey: "customRuleReleaseTempC")
        fixture.defaults.set(5.0, forKey: "customRuleFanPercent")

        _ = try LegacyTemperatureRuleMigration.migrate(
            userDefaults: fixture.defaults,
            rulesFilePath: fixture.rulesPath
        )
        let rule = try #require(RulePersistence.load(from: fixture.rulesPath).first)

        #expect(!rule.enabled)
        #expect(rule.condition.valueCelsius == 40)
        #expect(rule.untilTempBelowC == 39)
        #expect(rule.action == .setFanPercent(0.2))
    }

    @Test("Fresh installs are marked complete without creating a rule file")
    func noLegacySettings() throws {
        let fixture = MigrationFixture()
        defer { fixture.cleanUp() }

        #expect(try LegacyTemperatureRuleMigration.migrate(
            userDefaults: fixture.defaults,
            rulesFilePath: fixture.rulesPath
        ) == .noLegacySettings)
        #expect(try LegacyTemperatureRuleMigration.migrate(
            userDefaults: fixture.defaults,
            rulesFilePath: fixture.rulesPath
        ) == .alreadyCompleted)
        #expect(!FileManager.default.fileExists(atPath: fixture.rulesPath.path))
    }
}

private final class MigrationFixture {
    let suiteName = "ThermalForgeTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let rulesPath: URL

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        rulesPath = directory.appendingPathComponent("rules.json")
    }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
