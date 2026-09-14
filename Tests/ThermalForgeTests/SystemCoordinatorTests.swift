import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("System coordinators")
struct SystemCoordinatorTests {
    @Test("Launchd list distinguishes loaded and absent services")
    func launchdServiceState() throws {
        let loadedRunner = StubProcessRunner(results: [
            .init(
                standardOutput: "{\n    \"PID\" = 4321;\n}",
                standardError: "",
                terminationStatus: 0
            ),
        ])
        let loaded = try LaunchdCoordinator(processRunner: loadedRunner)
            .serviceState(label: "com.thermalforge.daemon")
        #expect(loaded == .loaded(pid: 4321))

        let absentRunner = StubProcessRunner(results: [
            .init(standardOutput: "", standardError: "", terminationStatus: 1),
        ])
        let absent = try LaunchdCoordinator(processRunner: absentRunner)
            .serviceState(label: "com.thermalforge.daemon")
        #expect(absent == .notLoaded)
    }

    @Test("Launchd list does not hide unexpected failures")
    func launchdListFailure() {
        let runner = StubProcessRunner(results: [
            .init(standardOutput: "", standardError: "permission denied", terminationStatus: 77),
        ])

        #expect(throws: LaunchdCoordinatorError.self) {
            try LaunchdCoordinator(processRunner: runner)
                .serviceState(label: "com.thermalforge.daemon")
        }
    }

    @Test("Launchd bootout and bootstrap use system-domain commands")
    func launchdMutationCommands() throws {
        let runner = StubProcessRunner(results: [
            .init(standardOutput: "", standardError: "", terminationStatus: 0),
            .init(standardOutput: "", standardError: "", terminationStatus: 0),
        ])
        let launchd = LaunchdCoordinator(processRunner: runner)

        try launchd.bootout(label: "com.thermalforge.daemon")
        try launchd.bootstrap(plistPath: "/tmp/thermalforge.plist")

        #expect(runner.commands.map(\.arguments) == [
            ["bootout", "system/com.thermalforge.daemon"],
            ["bootstrap", "system", "/tmp/thermalforge.plist"],
        ])
    }

    @Test("Launchd mutation failures include non-zero status")
    func launchdMutationFailure() {
        let runner = StubProcessRunner(results: [
            .init(standardOutput: "", standardError: "bootstrap failed", terminationStatus: 5),
        ])

        #expect(throws: LaunchdCoordinatorError.self) {
            try LaunchdCoordinator(processRunner: runner)
                .bootstrap(plistPath: "/tmp/thermalforge.plist")
        }
    }

    @Test("Loaded service without a PID remains distinguishable from absent")
    func loadedServiceWithoutPID() throws {
        let runner = StubProcessRunner(results: [
            .init(
                standardOutput: "{\n    \"Label\" = \"com.thermalforge.daemon\";\n}",
                standardError: "",
                terminationStatus: 0
            ),
        ])

        let state = try LaunchdCoordinator(processRunner: runner)
            .serviceState(label: "com.thermalforge.daemon")

        #expect(state == .loaded(pid: nil))
    }

    @Test("Missing menu-bar app is an expected condition")
    func missingApplicationIsExpected() throws {
        let runner = StubProcessRunner(results: [
            .init(standardOutput: "", standardError: "no process found", terminationStatus: 1),
        ])

        let stopped = try ApplicationLifecycleCoordinator(processRunner: runner)
            .stop(applicationName: "ThermalForgeApp")

        #expect(!stopped)
    }

    @Test("Running menu-bar app reports that it was stopped")
    func runningApplicationIsStopped() throws {
        let runner = StubProcessRunner(results: [
            .init(standardOutput: "", standardError: "", terminationStatus: 0),
        ])

        let stopped = try ApplicationLifecycleCoordinator(processRunner: runner)
            .stop(applicationName: "ThermalForgeApp")

        #expect(stopped)
        #expect(runner.commands.first?.arguments == ["ThermalForgeApp"])
    }

    @Test("Unexpected menu-bar stop failure is explicit")
    func applicationStopFailure() {
        let runner = StubProcessRunner(results: [
            .init(standardOutput: "", standardError: "not permitted", terminationStatus: 2),
        ])

        #expect(throws: ApplicationLifecycleError.self) {
            try ApplicationLifecycleCoordinator(processRunner: runner)
                .stop(applicationName: "ThermalForgeApp")
        }
    }

}

private final class StubProcessRunner: ProcessRunning {
    private(set) var commands: [ProcessCommand] = []
    private var results: [ProcessResult]

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(_ command: ProcessCommand) throws -> ProcessResult {
        commands.append(command)
        return results.removeFirst()
    }
}
