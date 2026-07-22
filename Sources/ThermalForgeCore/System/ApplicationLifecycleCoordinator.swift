import Foundation

public enum ApplicationLifecycleError: LocalizedError {
    case stopFailed(application: String, status: Int32, standardError: String)

    public var errorDescription: String? {
        switch self {
        case let .stopFailed(application, status, standardError):
            let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Stopping \(application) failed with status \(status)"
                : "Stopping \(application) failed with status \(status): \(detail)"
        }
    }
}

public protocol ApplicationStopping {
    @discardableResult
    func stop(applicationName: String) throws -> Bool
}

public struct ApplicationLifecycleCoordinator: ApplicationStopping {
    private let processRunner: any ProcessRunning
    private let executableURL: URL

    public init(
        processRunner: any ProcessRunning = ProcessRunner(),
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/killall")
    ) {
        self.processRunner = processRunner
        self.executableURL = executableURL
    }

    @discardableResult
    public func stop(applicationName: String) throws -> Bool {
        let result = try processRunner.run(
            executableURL: executableURL,
            arguments: [applicationName]
        )
        switch result.terminationStatus {
        case 0:
            return true
        case 1:
            return false
        default:
            throw ApplicationLifecycleError.stopFailed(
                application: applicationName,
                status: result.terminationStatus,
                standardError: result.standardError
            )
        }
    }
}
