import Darwin
import Foundation

public struct BackendProcessIdentity: Codable, Equatable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

public enum BackendProcessState { case alive, exited, unknown }

public protocol RecoveryProcessControlling: AnyObject {
    func identity(pid: Int32) -> BackendProcessIdentity?
    func state(of identity: BackendProcessIdentity) -> BackendProcessState
    func terminate(_ identity: BackendProcessIdentity, force: Bool) throws
}

public final class SystemRecoveryProcessControl: RecoveryProcessControlling {
    public init() {}
    public func identity(pid: Int32) -> BackendProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard count == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return BackendProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec,
                                      startMicroseconds: info.pbi_start_tvusec)
    }
    public func state(of expected: BackendProcessIdentity) -> BackendProcessState {
        if let current = identity(pid: expected.pid) {
            // PID reuse proves the original process exited; never signal its replacement.
            return current == expected ? .alive : .exited
        }
        if kill(expected.pid, 0) == -1, errno == ESRCH { return .exited }
        return .unknown
    }
    public func terminate(_ expected: BackendProcessIdentity, force: Bool) throws {
        guard state(of: expected) == .alive else { return }
        guard kill(expected.pid, force ? SIGKILL : SIGTERM) == 0 || errno == ESRCH else {
            throw RecoveryError.failure("Cannot terminate backend: errno \(errno)")
        }
    }
}

public struct RecoveryMarker: Codable, Equatable {
    public let version: Int
    public let identity: BackendProcessIdentity
    public let generation: String
    // Missing in older markers, which always represented manual ownership.
    public let manualControl: Bool?
    public var requiresProtection: Bool { manualControl ?? true }
    public init(identity: BackendProcessIdentity, generation: String, manualControl: Bool = true) {
        version = 1
        self.identity = identity
        self.generation = generation
        self.manualControl = manualControl
    }
}

public protocol RecoveryMarkerStoring: AnyObject {
    func load() throws -> RecoveryMarker?
    func save(_ marker: RecoveryMarker) throws
    func clear() throws
}

public enum RecoveryError: Error, CustomStringConvertible {
    case failure(String)
    public var description: String {
        switch self { case .failure(let message): return message }
    }
}

public enum RecoveryOperation: String, Codable { case connect, authorizeManual, completedWork, restored, status, inspect }
public struct RecoveryRequest: Codable {
    public let version: Int
    public let generation: String
    public let operation: RecoveryOperation
    public init(generation: String, operation: RecoveryOperation) {
        version = 1
        self.generation = generation
        self.operation = operation
    }
}

public struct RecoverySnapshot: Codable {
    public let ready: Bool
    public let protected: Bool
    public let revoked: Bool
    public let generation: String?
    public let restoration: RestorationResult

    public var readyForInstallation: Bool {
        ready && !protected && !revoked && generation == nil && restoration.verified
    }
}

public struct RecoveryResponse: Codable {
    public let ok: Bool
    public let error: String?
    public let snapshot: RecoverySnapshot
}

/// One identity and one durable marker. The queue deliberately serializes
/// permission revocation, process fencing and independent SMC restoration.
/// Transport servicing is separate and cannot refresh completed-work progress.
public final class RecoveryCoordinator {
    private let queue = DispatchQueue(label: "com.thermalforge.recovery.coordinator")
    private let markerStore: RecoveryMarkerStoring
    private let processes: RecoveryProcessControlling
    private let restore: () -> RestorationResult
    private let now: () -> TimeInterval
    private var marker: RecoveryMarker?
    private var registered: RecoveryMarker?
    private var lastProgress: TimeInterval?
    private var revoked = false
    private var terminationRequestedAt: TimeInterval?
    private var forced = false
    private var reconciled = false
    private var restoration = RestorationResult(verified: false, errors: ["Startup reconciliation pending"])

    public init(markerStore: RecoveryMarkerStoring, processControl: RecoveryProcessControlling,
                restore: @escaping () -> RestorationResult,
                now: @escaping () -> TimeInterval = { BackendTiming.monotonicNow }) throws {
        self.markerStore = markerStore
        self.processes = processControl
        self.restore = restore
        self.now = now
        marker = try markerStore.load()
        // Monotonic timestamps are intentionally not persisted: restart revokes
        // the old generation immediately, even if it is still responsive.
        if marker != nil { revoked = true }
    }

    public func snapshot() -> RecoverySnapshot { queue.sync { currentSnapshot() } }
    private func currentSnapshot() -> RecoverySnapshot {
        RecoverySnapshot(ready: reconciled && !revoked, protected: marker?.requiresProtection == true,
                         revoked: revoked, generation: registered?.generation ?? marker?.generation,
                         restoration: restoration)
    }

    public func handle(_ request: RecoveryRequest, peer: AuthenticatedPeer) -> RecoveryResponse {
        queue.sync {
            do {
                guard request.version == 1, !request.generation.isEmpty,
                      request.generation.utf8.count <= 128 else { throw RecoveryError.failure("Invalid recovery protocol") }
                if request.operation == .inspect {
                    return RecoveryResponse(ok: true, error: nil, snapshot: currentSnapshot())
                }
                // Production transport already requires root. Identity comes
                // exclusively from the authenticated socket's PID.
                guard let identity = processes.identity(pid: peer.pid) else {
                    throw RecoveryError.failure("Cannot authenticate backend process identity")
                }
                if marker?.requiresProtection == true, let lastProgress,
                   now() - lastProgress >= BackendTiming.protectionLease {
                    revoked = true
                    restoration = RestorationResult(verified: false, errors: ["Backend completed-work lease expired"])
                }
                guard reconciled, !revoked else { throw RecoveryError.failure("Recovery reconciliation pending or permission revoked") }
                let caller = RecoveryMarker(identity: identity, generation: request.generation)
                if request.operation == .connect {
                    if let registered, registered != caller {
                        throw RecoveryError.failure("A different backend is registered")
                    }
                    if registered == nil {
                        // Remember even an idle backend durably. Otherwise a recovery
                        // restart could reset hardware while that backend is still alive.
                        let idle = RecoveryMarker(identity: identity, generation: request.generation, manualControl: false)
                        try markerStore.save(idle)
                        marker = idle
                    }
                    registered = caller
                }
                guard registered == caller else { throw RecoveryError.failure("Stale backend identity or generation") }
                switch request.operation {
                case .connect, .status, .inspect: break
                case .authorizeManual:
                    if marker?.requiresProtection != true {
                        // Permission must never escape if any durable step fails.
                        try markerStore.save(caller)
                        marker = caller
                        lastProgress = now()
                        restoration = RestorationResult(verified: false, errors: ["Backend owns manual control"])
                    }
                case .completedWork:
                    if marker?.requiresProtection == true { lastProgress = now() }
                case .restored:
                    // Only the backend's verified actuator result permits this
                    // acknowledgement. Once revoked it must exit instead.
                    if marker?.requiresProtection == true {
                        let idle = RecoveryMarker(identity: identity, generation: request.generation, manualControl: false)
                        try markerStore.save(idle)
                        marker = idle
                    }
                    lastProgress = nil
                    restoration = RestorationResult(verified: true)
                }
                return RecoveryResponse(ok: true, error: nil, snapshot: currentSnapshot())
            } catch {
                return RecoveryResponse(ok: false, error: String(describing: error), snapshot: currentSnapshot())
            }
        }
    }

    /// Called every second, independent of request traffic and backend progress.
    public func tick() { queue.sync { tickLocked() } }
    private func tickLocked() {
        if let marker {
            let state = processes.state(of: marker.identity)
            if state != .alive || (marker.requiresProtection && (lastProgress.map({ now() - $0 >= BackendTiming.protectionLease }) ?? true)) {
                revoked = true
            }
            guard revoked else { return }
            // No recovery writes until positive evidence of the original
            // identity's exit. Unknown/EPERM remains blocked indefinitely.
            guard state == .exited else {
                if terminationRequestedAt == nil {
                    terminationRequestedAt = now()
                    do { try processes.terminate(marker.identity, force: false) }
                    catch { restoration = RestorationResult(verified: false, errors: [String(describing: error)]) }
                } else if now() - terminationRequestedAt! >= BackendTiming.terminationGrace {
                    do { try processes.terminate(marker.identity, force: true); forced = true }
                    catch { restoration = RestorationResult(verified: false, errors: [String(describing: error)]) }
                }
                restoration = RestorationResult(verified: false,
                    errors: restoration.errors + [forced ? "Awaiting backend exit after SIGKILL" : "Awaiting backend exit"])
                // Bound diagnostic growth during a permanently unkillable process.
                restoration.errors = Array(restoration.errors.suffix(8))
                return
            }
            restoration = restore()
            guard restoration.verified else { return }
            do { try markerStore.clear() }
            catch {
                restoration = RestorationResult(verified: false, errors: ["Cannot clear recovery marker: \(error)"])
                return
            }
            self.marker = nil
            registered = nil
            lastProgress = nil
            revoked = false
            terminationRequestedAt = nil
            forced = false
            reconciled = true
        } else if !reconciled {
            restoration = restore()
            reconciled = restoration.verified
        }
    }
}
