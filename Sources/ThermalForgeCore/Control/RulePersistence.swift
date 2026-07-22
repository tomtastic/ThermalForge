import Foundation

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
}
