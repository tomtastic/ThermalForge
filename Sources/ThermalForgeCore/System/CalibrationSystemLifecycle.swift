import Foundation

public enum CalibrationLifecycleEvent: Equatable {
    case daemonStopped(pid: Int32?)
    case daemonResuming
}

public struct CalibrationLifecycleRestorationError: LocalizedError {
    public let operationError: Error
    public let restorationError: Error

    public var errorDescription: String? {
        "Calibration failed: \(operationError.localizedDescription). " +
            "The daemon also failed to resume: \(restorationError.localizedDescription)"
    }
}

public struct CalibrationSystemLifecycle {
    private let launchd: any LaunchdCoordinating
    private let applications: any ApplicationStopping
    private let daemonLabel: String
    private let daemonPlistPath: String

    public init(
        launchd: any LaunchdCoordinating = LaunchdCoordinator(),
        applications: any ApplicationStopping = ApplicationLifecycleCoordinator(),
        daemonLabel: String = ThermalForgeDaemon.label,
        daemonPlistPath: String = ThermalForgeDaemon.plistPath
    ) {
        self.launchd = launchd
        self.applications = applications
        self.daemonLabel = daemonLabel
        self.daemonPlistPath = daemonPlistPath
    }

    public func withPausedServices<T>(
        onEvent: (CalibrationLifecycleEvent) -> Void = { _ in },
        operation: () throws -> T
    ) throws -> T {
        let state = try launchd.serviceState(label: daemonLabel)
        let daemonWasLoaded: Bool
        switch state {
        case .notLoaded:
            daemonWasLoaded = false
        case let .loaded(pid):
            daemonWasLoaded = true
            try launchd.bootout(label: daemonLabel)
            onEvent(.daemonStopped(pid: pid))
        }

        let operationResult: Result<T, Error>
        do {
            _ = try applications.stop(applicationName: "ThermalForgeApp")
            operationResult = Result { try operation() }
        } catch {
            operationResult = .failure(error)
        }

        let restorationResult: Result<Void, Error>
        if daemonWasLoaded {
            onEvent(.daemonResuming)
            restorationResult = Result {
                try launchd.bootstrap(plistPath: daemonPlistPath)
            }
        } else {
            restorationResult = .success(())
        }

        switch (operationResult, restorationResult) {
        case let (.success(value), .success):
            return value
        case let (.failure(error), .success):
            throw error
        case let (.success, .failure(error)):
            throw error
        case let (.failure(operationError), .failure(restorationError)):
            throw CalibrationLifecycleRestorationError(
                operationError: operationError,
                restorationError: restorationError
            )
        }
    }
}
