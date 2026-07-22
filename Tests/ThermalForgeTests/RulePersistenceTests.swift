import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Rule persistence")
struct RulePersistenceTests {
    @Test("Add appends and persists a rule")
    func add() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = Self.rule(id: "first")
        let second = Self.rule(id: "second")
        try RulePersistence.save([first], to: fixture.path)

        let rules = try RulePersistence.add(second, to: fixture.path)

        #expect(rules == [first, second])
        #expect(RulePersistence.load(from: fixture.path) == rules)
    }

    @Test("Remove reports every matching persisted rule")
    func remove() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let duplicate = Self.rule(id: "duplicate")
        let survivor = Self.rule(id: "survivor")
        try RulePersistence.save([duplicate, survivor, duplicate], to: fixture.path)

        let result = try RulePersistence.remove(id: duplicate.id, from: fixture.path)

        #expect(result.removedCount == 2)
        #expect(result.rules == [survivor])
        #expect(RulePersistence.load(from: fixture.path) == [survivor])
    }

    @Test("Enable updates and persists the requested rule")
    func enable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var disabled = Self.rule(id: "target")
        disabled.enabled = false
        let untouched = Self.rule(id: "other")
        try RulePersistence.save([disabled, untouched], to: fixture.path)

        let updated = try RulePersistence.enable(id: disabled.id, in: fixture.path)
        let rules = try #require(updated)

        #expect(rules[0].enabled)
        #expect(rules[1] == untouched)
        #expect(RulePersistence.load(from: fixture.path) == rules)
    }

    @Test("Disable updates and persists the requested rule")
    func disable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let enabled = Self.rule(id: "target")
        try RulePersistence.save([enabled], to: fixture.path)

        let updated = try RulePersistence.disable(id: enabled.id, in: fixture.path)
        let rules = try #require(updated)

        #expect(!rules[0].enabled)
        #expect(RulePersistence.load(from: fixture.path) == rules)
    }

    @Test("Replace updates an existing rule and leaves absent IDs unchanged")
    func replace() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Self.rule(id: "target")
        var replacement = original
        replacement.name = "Replacement"
        try RulePersistence.save([original], to: fixture.path)

        let updated = try RulePersistence.replace(replacement, in: fixture.path)
        let rules = try #require(updated)
        let missing = try RulePersistence.replace(Self.rule(id: "missing"), in: fixture.path)

        #expect(rules == [replacement])
        #expect(missing == nil)
        #expect(RulePersistence.load(from: fixture.path) == [replacement])
    }

    private static func rule(id: String) -> ThermalRule {
        ThermalRule(
            id: id,
            name: id,
            condition: ThermalRuleCondition(
                metric: .maxTemp,
                comparator: .greaterThanOrEqual,
                valueCelsius: 60
            ),
            action: .setMax
        )
    }
}

private struct Fixture {
    let directory: URL
    let path: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThermalForgeRulePersistenceTests-\(UUID().uuidString)")
        path = directory.appendingPathComponent("rules.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
