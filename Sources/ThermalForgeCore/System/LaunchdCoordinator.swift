import Foundation

public enum LaunchdServiceState: Equatable {
    case notLoaded
    case loaded(pid: Int32?)
}

public enum LaunchdCoordinatorError: LocalizedError {
    case commandFailed(action: String, status: Int32, standardError: String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(action, status, standardError):
            let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "launchctl \(action) failed with status \(status)"
                : "launchctl \(action) failed with status \(status): \(detail)"
        }
    }
}

public protocol LaunchdCoordinating {
    func serviceState(label: String) throws -> LaunchdServiceState
    func bootout(label: String) throws
    func bootstrap(plistPath: String) throws
}

public struct LaunchdCoordinator: LaunchdCoordinating {
    private let processRunner: any ProcessRunning
    private let executableURL: URL

    public init(
        processRunner: any ProcessRunning = ProcessRunner(),
        executableURL: URL = URL(fileURLWithPath: "/bin/launchctl")
    ) {
        self.processRunner = processRunner
        self.executableURL = executableURL
    }

    public func serviceState(label: String) throws -> LaunchdServiceState {
        let result = try processRunner.run(
            executableURL: executableURL,
            arguments: ["list", label]
        )
        if result.terminationStatus == 1 {
            return .notLoaded
        }
        guard result.succeeded else {
            throw failure(action: "list", result: result)
        }
        return .loaded(pid: Self.parsePID(from: result.standardOutput, label: label))
    }

    public func bootout(label: String) throws {
        let result = try processRunner.run(
            executableURL: executableURL,
            arguments: ["bootout", "system/\(label)"]
        )
        guard result.succeeded else {
            throw failure(action: "bootout", result: result)
        }
    }

    public func bootstrap(plistPath: String) throws {
        let result = try processRunner.run(
            executableURL: executableURL,
            arguments: ["bootstrap", "system", plistPath]
        )
        guard result.succeeded else {
            throw failure(action: "bootstrap", result: result)
        }
    }

    static func parsePID(from output: String, label: String) -> Int32? {
        for line in output.components(separatedBy: .newlines) {
            if line.contains("\"PID\"") || line.contains("pid =") {
                let digits = line.split { !$0.isNumber }
                if let value = digits.first.flatMap({ Int32($0) }), value > 0 {
                    return value
                }
            }
            if line.contains(label) {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if let value = fields.first.flatMap({ Int32($0) }), value > 0 {
                    return value
                }
            }
        }
        return nil
    }

    private func failure(action: String, result: ProcessResult) -> LaunchdCoordinatorError {
        .commandFailed(
            action: action,
            status: result.terminationStatus,
            standardError: result.standardError
        )
    }
}
