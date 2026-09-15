import Darwin
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
            var info = stat()
            guard lstat(target.path, &info) == 0 else {
                if errno != ENOENT {
                    return UninstallRemovalResult(path: target, outcome: .failed("Cannot inspect path: errno \(errno)"))
                }
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
        URL(fileURLWithPath: ThermalForgeDaemon.recoveryPlistPath),
        URL(fileURLWithPath: ThermalForgeDaemon.installPath).deletingLastPathComponent(),
        URL(fileURLWithPath: ThermalForgeDaemon.cliPath),
        URL(fileURLWithPath: ThermalForgeDaemon.socketPath),
        URL(fileURLWithPath: RecoveryService.socketPath),
        URL(fileURLWithPath: ThermalForgeDaemon.stateDirectory, isDirectory: true),
        URL(fileURLWithPath: "/Applications/ThermalForge.app", isDirectory: true),
    ]
}
