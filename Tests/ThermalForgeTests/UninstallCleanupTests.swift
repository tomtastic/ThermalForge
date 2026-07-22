import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Uninstall cleanup")
struct UninstallCleanupTests {
    @Test("Home resolver includes root and console user once")
    func homeResolverDeduplicatesHomes() {
        let rootHome = URL(fileURLWithPath: "/var/root", isDirectory: true)
        let userHome = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        #expect(
            UserHomeDirectoryResolver.homeDirectories(
                currentHome: rootHome,
                consoleHome: userHome
            ) == [rootHome, userHome]
        )
        #expect(
            UserHomeDirectoryResolver.homeDirectories(
                currentHome: userHome,
                consoleHome: userHome
            ) == [userHome]
        )
    }

    @Test("Plan covers system, root, and console-user data")
    func planCoversEveryOwnedLocation() {
        let rootHome = URL(fileURLWithPath: "/var/root", isDirectory: true)
        let userHome = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let systemTargets = [
            URL(fileURLWithPath: "/system/daemon.plist"),
            URL(fileURLWithPath: "/system/thermalforge"),
        ]
        let cleanup = UninstallCleanup(
            homeDirectories: [rootHome, userHome],
            systemTargets: systemTargets
        )

        #expect(cleanup.targets.count == 6)
        let targetPaths = Set(cleanup.targets.map(\.path))
        #expect(targetPaths.contains(systemTargets[0].path))
        #expect(targetPaths.contains(
            rootHome.appendingPathComponent("Library/Application Support/ThermalForge").path
        ))
        #expect(targetPaths.contains(
            rootHome.appendingPathComponent("Library/Logs/ThermalForge").path
        ))
        #expect(targetPaths.contains(
            userHome.appendingPathComponent("Library/Application Support/ThermalForge").path
        ))
        #expect(targetPaths.contains(
            userHome.appendingPathComponent("Library/Logs/ThermalForge").path
        ))
    }

    @Test("Removal reports removed and absent paths")
    func removalUsesInjectedTemporaryPaths() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let existing = temporaryRoot.appendingPathComponent("existing", isDirectory: true)
        let absent = temporaryRoot.appendingPathComponent("absent", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        let cleanup = UninstallCleanup(
            homeDirectories: [],
            systemTargets: [existing, absent]
        )
        let results = cleanup.remove()

        #expect(results.count == 2)
        if case .removed = results[0].outcome {
            // Expected.
        } else {
            Issue.record("Expected existing path to be removed")
        }
        if case .alreadyAbsent = results[1].outcome {
            // Expected.
        } else {
            Issue.record("Expected missing path to be reported as absent")
        }
        #expect(!FileManager.default.fileExists(atPath: existing.path))
    }
}
