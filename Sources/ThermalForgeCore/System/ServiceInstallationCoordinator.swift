import Foundation

public enum ServiceInstallationError: LocalizedError {
    case restorationUnverified([String])
    case serviceUnavailable(String, detail: String? = nil)
    public var errorDescription: String? {
        switch self {
        case .restorationUnverified(let errors):
            return "Apple fan ownership is unverified; recovery is retained and new control remains blocked. " + errors.joined(separator: "; ")
        case .serviceUnavailable(let label, let detail):
            return "Service did not become ready: \(label)" + (detail.map { ". \($0)" } ?? "")
        }
    }
}

/// The same ordering is used by installation, upgrades, and isolated integration tests.
public struct ServiceInstallationCoordinator {
    public var stopControllers: () throws -> Void
    public var restore: () throws -> RestorationResult
    public var stopRecovery: () throws -> Void
    public var stageFiles: () throws -> Void
    public var startRecovery: () throws -> Void
    public var startBackend: () throws -> Void
    public var removeFiles: () throws -> Void

    public init(stopControllers: @escaping () throws -> Void,
                restore: @escaping () throws -> RestorationResult,
                stopRecovery: @escaping () throws -> Void,
                stageFiles: @escaping () throws -> Void,
                startRecovery: @escaping () throws -> Void,
                startBackend: @escaping () throws -> Void,
                removeFiles: @escaping () throws -> Void = {}) {
        self.stopControllers = stopControllers
        self.restore = restore
        self.stopRecovery = stopRecovery
        self.stageFiles = stageFiles
        self.startRecovery = startRecovery
        self.startBackend = startBackend
        self.removeFiles = removeFiles
    }

    public func install() throws {
        try stopControllers()
        try verifyRestoration()
        try stopRecovery()
        try stageFiles()
        try startRecovery()
        try startBackend()
    }

    public func uninstall() throws {
        try stopControllers()
        try verifyRestoration()
        try stopRecovery()
        try removeFiles()
    }

    private func verifyRestoration() throws {
        let result = try restore()
        guard result.verified else { throw ServiceInstallationError.restorationUnverified(result.errors) }
    }
}
