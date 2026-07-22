import Foundation

public struct RuleRemovalResult: Equatable {
    public let rules: [ThermalRule]
    public let removedCount: Int
}

public enum RulePersistence {
    public static var filePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/rules.json")
    }

    public static func load() -> [ThermalRule] {
        load(from: filePath)
    }

    static func load(from path: URL) -> [ThermalRule] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        guard let data = try? Data(contentsOf: path) else { return [] }
        return (try? JSONDecoder().decode([ThermalRule].self, from: data)) ?? []
    }

    public static func save(_ rules: [ThermalRule]) throws {
        try save(rules, to: filePath)
    }

    static func save(_ rules: [ThermalRule], to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try data.write(to: path)
    }

    @discardableResult
    public static func add(_ rule: ThermalRule) throws -> [ThermalRule] {
        try add(rule, to: filePath)
    }

    @discardableResult
    static func add(_ rule: ThermalRule, to path: URL) throws -> [ThermalRule] {
        var rules = load(from: path)
        rules.append(rule)
        try save(rules, to: path)
        return rules
    }

    @discardableResult
    public static func remove(id: String) throws -> RuleRemovalResult {
        try remove(id: id, from: filePath)
    }

    @discardableResult
    static func remove(id: String, from path: URL) throws -> RuleRemovalResult {
        var rules = load(from: path)
        let originalCount = rules.count
        rules.removeAll(where: { $0.id == id })
        try save(rules, to: path)
        return RuleRemovalResult(
            rules: rules,
            removedCount: originalCount - rules.count
        )
    }

    @discardableResult
    public static func enable(id: String) throws -> [ThermalRule]? {
        try setEnabled(true, id: id, in: filePath)
    }

    @discardableResult
    public static func disable(id: String) throws -> [ThermalRule]? {
        try setEnabled(false, id: id, in: filePath)
    }

    static func enable(id: String, in path: URL) throws -> [ThermalRule]? {
        try setEnabled(true, id: id, in: path)
    }

    static func disable(id: String, in path: URL) throws -> [ThermalRule]? {
        try setEnabled(false, id: id, in: path)
    }

    @discardableResult
    public static func replace(_ rule: ThermalRule) throws -> [ThermalRule]? {
        try replace(rule, in: filePath)
    }

    static func replace(_ rule: ThermalRule, in path: URL) throws -> [ThermalRule]? {
        var rules = load(from: path)
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else {
            return nil
        }
        rules[index] = rule
        try save(rules, to: path)
        return rules
    }

    private static func setEnabled(
        _ enabled: Bool,
        id: String,
        in path: URL
    ) throws -> [ThermalRule]? {
        var rules = load(from: path)
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        rules[index].enabled = enabled
        try save(rules, to: path)
        return rules
    }
}
