import ArgumentParser
import Foundation
import ThermalForgeCore

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall",
        abstract: "Verify Apple handback and remove both background services")
    func run() throws {
        guard geteuid() == 0 else { throw ValidationError("Run with sudo: sudo thermalforge uninstall") }
        let transaction = try ServiceInstallationLock()
        defer { withExtendedLifetime(transaction) {} }
        let cleanup = UninstallCleanup()
        try InstalledServiceManager().coordinator {
            let failures = cleanup.remove().compactMap { result -> String? in
                if case .failed(let error) = result.outcome { return "\(result.path.path): \(error)" }
                return nil
            }
            guard failures.isEmpty else { throw ValidationError(failures.joined(separator: "\n")) }
        }.uninstall()
        print("Apple ownership verified. Backend, recovery, and application removed.")
    }
}
