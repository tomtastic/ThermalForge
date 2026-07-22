import Foundation

public struct UninstallRemovalResult {
    public enum Outcome {
        case removed
        case alreadyAbsent
        case failed(String)
    }

    public let path: URL
    public let outcome: Outcome
}

/// Defines and removes the narrow set of files owned by ThermalForge.
public struct UninstallCleanup {
    public let targets: [URL]

    public init() {
        self.init(
            homeDirectories: UserHomeDirectoryResolver.rootAndConsoleUserHomes(),
            systemTargets: Self.defaultSystemTargets
        )
    }

    init(homeDirectories: [URL], systemTargets: [URL]) {
        var targets = systemTargets.map(\.standardizedFileURL)
        for home in homeDirectories {
            targets.append(
                home.appendingPathComponent(
                    "Library/Application Support/ThermalForge",
                    isDirectory: true
                ).standardizedFileURL
            )
            targets.append(
                home.appendingPathComponent(
                    "Library/Logs/ThermalForge",
                    isDirectory: true
                ).standardizedFileURL
            )
        }
        self.targets = targets.reduce(into: []) { uniqueTargets, target in
            if !uniqueTargets.contains(target) {
                uniqueTargets.append(target)
            }
        }
    }

    public func remove(fileManager: FileManager = .default) -> [UninstallRemovalResult] {
        targets.map { target in
            guard fileManager.fileExists(atPath: target.path) else {
                return UninstallRemovalResult(path: target, outcome: .alreadyAbsent)
            }

            do {
                try fileManager.removeItem(at: target)
                return UninstallRemovalResult(path: target, outcome: .removed)
            } catch {
                return UninstallRemovalResult(path: target, outcome: .failed(error.localizedDescription))
            }
        }
    }

    private static let defaultSystemTargets = [
        URL(fileURLWithPath: ThermalForgeDaemon.plistPath),
        URL(fileURLWithPath: ThermalForgeDaemon.installPath),
        URL(fileURLWithPath: ThermalForgeDaemon.socketPath),
        URL(fileURLWithPath: "/Applications/ThermalForge.app", isDirectory: true),
    ]
}
