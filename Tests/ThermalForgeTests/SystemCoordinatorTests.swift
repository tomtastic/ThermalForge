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

    @Test("Missing menu-bar app is an expected condition")
    func missingApplicationIsExpected() throws {
        let runner = StubProcessRunner(results: [
            .init(standardOutput: "", standardError: "no process found", terminationStatus: 1),
        ])

        let stopped = try ApplicationLifecycleCoordinator(processRunner: runner)
            .stop(applicationName: "ThermalForgeApp")

        #expect(!stopped)
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

    @Test("Calibration restores a loaded daemon after success")
    func calibrationRestoresAfterSuccess() throws {
        let launchd = StubLaunchd(state: .loaded(pid: 123))
        let applications = StubApplicationStopper()
        var events: [CalibrationLifecycleEvent] = []
        var operationRan = false

        try CalibrationSystemLifecycle(
            launchd: launchd,
            applications: applications,
            daemonLabel: "test.daemon",
            daemonPlistPath: "/tmp/test.plist"
        ).withPausedServices(onEvent: { events.append($0) }) {
            operationRan = true
        }

        #expect(operationRan)
        #expect(applications.stoppedApplications == ["ThermalForgeApp"])
        #expect(launchd.calls == [
            "state:test.daemon",
            "bootout:test.daemon",
            "bootstrap:/tmp/test.plist",
        ])
        #expect(events == [.daemonStopped(pid: 123), .daemonResuming])
    }

    @Test("Calibration restores the daemon after operation failure")
    func calibrationRestoresAfterFailure() {
        let launchd = StubLaunchd(state: .loaded(pid: nil))
        let lifecycle = CalibrationSystemLifecycle(
            launchd: launchd,
            applications: StubApplicationStopper()
        )

        #expect(throws: StubError.operation) {
            try lifecycle.withPausedServices {
                throw StubError.operation
            }
        }
        #expect(launchd.calls.contains("bootstrap:\(ThermalForgeDaemon.plistPath)"))
    }

    @Test("Calibration restores the daemon when stopping the app fails")
    func calibrationRestoresAfterApplicationFailure() {
        let launchd = StubLaunchd(state: .loaded(pid: 123))
        let applications = StubApplicationStopper(error: StubError.application)
        var operationRan = false
        let lifecycle = CalibrationSystemLifecycle(
            launchd: launchd,
            applications: applications
        )

        #expect(throws: StubError.application) {
            try lifecycle.withPausedServices {
                operationRan = true
            }
        }
        #expect(!operationRan)
        #expect(launchd.calls.contains("bootstrap:\(ThermalForgeDaemon.plistPath)"))
    }

    @Test("Calibration reports daemon restoration failure")
    func calibrationReportsRestorationFailure() {
        let launchd = StubLaunchd(
            state: .loaded(pid: 123),
            bootstrapError: StubError.bootstrap
        )
        let lifecycle = CalibrationSystemLifecycle(
            launchd: launchd,
            applications: StubApplicationStopper()
        )

        #expect(throws: StubError.bootstrap) {
            try lifecycle.withPausedServices {}
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

private final class StubLaunchd: LaunchdCoordinating {
    let state: LaunchdServiceState
    let bootoutError: Error?
    let bootstrapError: Error?
    private(set) var calls: [String] = []

    init(
        state: LaunchdServiceState,
        bootoutError: Error? = nil,
        bootstrapError: Error? = nil
    ) {
        self.state = state
        self.bootoutError = bootoutError
        self.bootstrapError = bootstrapError
    }

    func serviceState(label: String) throws -> LaunchdServiceState {
        calls.append("state:\(label)")
        return state
    }

    func bootout(label: String) throws {
        calls.append("bootout:\(label)")
        if let bootoutError { throw bootoutError }
    }

    func bootstrap(plistPath: String) throws {
        calls.append("bootstrap:\(plistPath)")
        if let bootstrapError { throw bootstrapError }
    }
}

private final class StubApplicationStopper: ApplicationStopping {
    let error: Error?
    private(set) var stoppedApplications: [String] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func stop(applicationName: String) throws -> Bool {
        stoppedApplications.append(applicationName)
        if let error { throw error }
        return true
    }
}

private enum StubError: Error {
    case operation
    case application
    case bootstrap
}
