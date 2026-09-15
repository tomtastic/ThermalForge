import Foundation

/// Repairs an unreachable recovery job only after the installer fenced all
/// controllers. The old recovery process must also exit before local recovery
/// opens SMC. Durable backend identities still go through normal reconciliation.
public struct RecoveryServiceRepair {
    private let stop: () throws -> Void
    private let makeCoordinator: () throws -> RecoveryCoordinator
    private let restart: () throws -> Void
    private let now: () -> TimeInterval
    private let wait: (TimeInterval) -> Void

    public init(stop: @escaping () throws -> Void,
                makeCoordinator: @escaping () throws -> RecoveryCoordinator,
                restart: @escaping () throws -> Void,
                now: @escaping () -> TimeInterval = { BackendTiming.monotonicNow },
                wait: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) {
        self.stop = stop
        self.makeCoordinator = makeCoordinator
        self.restart = restart
        self.now = now
        self.wait = wait
    }

    public func restore(timeout: TimeInterval = 15) -> RestorationResult {
        var result = RestorationResult(verified: false, errors: ["Recovery repair pending"])
        do {
            try stop()
            let coordinator = try makeCoordinator()
            let deadline = now() + timeout
            repeat {
                coordinator.tick()
                let snapshot = coordinator.snapshot()
                result = snapshot.restoration
                if snapshot.readyForInstallation { return result }
                if now() >= deadline { break }
                wait(min(BackendTiming.expiryInterval, max(0, deadline - now())))
            } while true
        } catch {
            result = .init(verified: false, errors: [String(describing: error)])
        }
        // Failed repair never authorizes replacement or uninstall. Retain the
        // existing recovery job and marker so it can keep retrying restoration.
        result.verified = false
        result.errors.append("Independent recovery repair could not verify handback")
        do { try restart() }
        catch { result.errors.append("Cannot restart retained recovery: \(error)") }
        return result
    }
}
